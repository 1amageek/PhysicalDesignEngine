import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import DRCNative
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutIR
import MaskGeometry

/// Projects retained physical surfaces once; lower owners compute rules and contact topology.
struct PhysicalDesignRepairProjection {
    let rectangles: [NativeDRCRectangle]
    let sourceIDByRecordID: [String: String]
    let integerBounds: [String: PhysicalDesignSnapshot.Rect]
    let targetGatePinIDs: [String]
    let targetAntennaNetIDs: Set<String>
    let snapshot: PhysicalDesignSnapshot
    let geometry: PhysicalDesignProcessGeometry
    let limits: PhysicalDesignRepairMeasurementLimits

    init(snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry,
         profile: PhysicalDesignRepairMeasurementProfile, limits: PhysicalDesignRepairMeasurementLimits, requireGateFacts: Bool) throws {
        try geometry.validate(snapshot)
        self.snapshot = snapshot; self.geometry = geometry; self.limits = limits
        let targets = Set(profile.antennaNetIDs)
        targetAntennaNetIDs = targets
        var records: [NativeDRCRectangle] = [], gates: [String] = []
        var bounds: [String: PhysicalDesignSnapshot.Rect] = [:]
        var sources: [String: String] = [:]
        var budget = try RectilinearUnionBudget(limits: .init(maximumInputEntries: limits.maximumProjectionRecords,
            maximumEdgeProbes: limits.maximumGeometryProbes, maximumIntermediateBands: limits.maximumProjectionRecords,
            maximumSweepWork: limits.maximumGeometryProbes, maximumOutputBands: limits.maximumProjectionRecords))
        let diffusionRequired = profile.rules.contains { $0.antennaLayers?.contains { $0.diffusionCorrection != .none } == true }
        func append(_ shapes: [IRBoundary], id: String, net: String?, gateArea: Double? = nil, diffusionArea: Double? = nil) throws {
            var annotated = false
            for shape in shapes {
                guard let source = geometry.sourceLayers[shape.layer] else { throw PhysicalDesignTechnologyError.invalid("Unmapped projection layer.") }
                let bands = try Region(layer: shape.layer, polygons: [shape]).rectilinearUnionBands(toPolygonIndex: 0, budget: &budget, isCancelled: { Task.isCancelled })
                for band in bands {
                    try Task.checkCancellation()
                    guard records.count < limits.maximumProjectionRecords else { throw PhysicalDesignTechnologyError.invalid("Repair projection record ceiling exhausted.") }
                    let annotate = !annotated && source.type == .routing
                    let scale = Double(snapshot.unitsPerMicron)
                    let recordID = "\(id):\(records.count)"
                    sources[recordID] = id
                    bounds[recordID] = .init(x: Int64(band.minX), y: Int64(band.minY),
                        width: Int64(band.maxX) - Int64(band.minX), height: Int64(band.maxY) - Int64(band.minY))
                    records.append(.init(id: recordID, layer: source.name,
                        xMin: Double(band.minX) / scale, yMin: Double(band.minY) / scale,
                        xMax: Double(band.maxX) / scale, yMax: Double(band.maxY) / scale, netID: net,
                        antennaGateArea: annotate ? gateArea : nil, antennaDiffusionArea: annotate ? diffusionArea : nil))
                    if annotate { annotated = true }
                }
            }
            guard annotated || gateArea == nil else { throw PhysicalDesignTechnologyError.invalid("Gate has no exact routing PORT surface.") }
        }
        for cell in snapshot.cells {
            let master = try geometry.requireMaster(cell.master)
            for name in master.pins.keys.sorted() {
                let pin = snapshot.pins.first { $0.cellID == cell.id && $0.name == name }
                let source = master.pins[name]!.definition
                var gate: Double?, diffusion: Double?
                if requireGateFacts, let pin, pin.netID.map({ targets.contains($0) }) == true {
                    if pin.direction == "input" || (source.antennaGateArea ?? 0) > 0 {
                        guard let area = source.antennaGateArea, area.isFinite, area > 0 else {
                            throw PhysicalDesignTechnologyError.invalid("Target gate \(pin.id) requires exact source ANTENNAGATEAREA.")
                        }
                        gate = area; gates.append(pin.id)
                    }
                    if let area = source.antennaDiffArea {
                        guard area.isFinite, area >= 0 else { throw PhysicalDesignTechnologyError.invalid("Invalid source diffusion area.") }
                        diffusion = area
                    } else if diffusionRequired {
                        throw PhysicalDesignTechnologyError.invalid("Diffusion correction requires complete source ANTENNADIFFAREA for \(pin.id).")
                    }
                }
                let shapes = try geometry.pinShapes(master: cell.master, pin: name, orientation: cell.orientation, x: cell.x, y: cell.y)
                try append(shapes, id: "pin:\(pin?.id ?? cell.id + "/" + name)", net: pin?.netID, gateArea: gate, diffusionArea: diffusion)
            }
        }
        for pin in snapshot.pins where pin.cellID == nil {
            guard let port = pin.topPort else { throw PhysicalDesignTechnologyError.invalid("Repair requires exact top PORT geometry.") }
            let region = try PhysicalDesignSourceRouter.rectangle(port.worldRectangle(), layer: port.layer)
            try append(region.polygons, id: "pin:\(pin.id)", net: pin.netID)
        }
        for route in snapshot.routes {
            for segment in route.segments {
                guard let width = segment.widthDBU else { throw PhysicalDesignTechnologyError.invalid("Repair requires retained conductor width.") }
                _ = try geometry.routingWidthAndSpacing(layer: segment.layer, units: snapshot.unitsPerMicron, width: width,
                    explicitSpecialWidth: snapshot.nets.first { $0.id == route.netID }?.routingClass == .special, areaHandledSeparately: true)
                try append(PhysicalDesignSourceRouter.conductor(segment, width: width).polygons, id: "route:\(route.id):\(segment.id)", net: route.netID)
            }
        }
        for via in snapshot.vias {
            guard let master = via.master else { throw PhysicalDesignTechnologyError.invalid("Repair requires named exact contacts.") }
            try append(geometry.viaShapes(master: master, x: via.x, y: via.y), id: "via:\(via.id)", net: via.netID)
        }
        for fill in snapshot.fills { try append(PhysicalDesignSourceRouter.rectangle(fill.geometry, layer: fill.layer).polygons, id: "fill:\(fill.id)", net: nil) }
        guard snapshot.powerStructures.isEmpty else { throw PhysicalDesignTechnologyError.unsupported("Repair requires retained exact power conductors.") }
        if requireGateFacts {
            for net in targets {
                guard snapshot.nets.contains(where: { $0.id == net }), snapshot.pins.contains(where: { $0.netID == net && gates.contains($0.id) }) else {
                    throw PhysicalDesignTechnologyError.invalid("Target antenna net has no complete source-bound gate coverage.")
                }
            }
        }
        rectangles = records; sourceIDByRecordID = sources; integerBounds = bounds; targetGatePinIDs = gates.sorted()
    }

    func layout(rule: NativeDRCRule) throws -> NativeDRCLayout {
        let records: [NativeDRCRectangle]
        if rule.kind == .maximumAntennaRatio {
            guard let step = rule.processStep, !step.isEmpty else { throw PhysicalDesignTechnologyError.invalid("Antenna rules require an explicit etch step.") }
            let active = Set((rule.antennaLayers ?? []).map(\.layer))
            let cuts = Set((rule.antennaCutConnections ?? []).map(\.layer))
            for gate in rectangles where (gate.antennaGateArea ?? 0) > 0 {
                guard rule.gateLayer == nil || rule.gateLayer == gate.layer else {
                    throw PhysicalDesignTechnologyError.unsupported("The selected native antenna law cannot omit any target gate layer.")
                }
            }
            records = rectangles.filter { $0.netID.map { targetAntennaNetIDs.contains($0) } == true && (active.contains($0.layer) || cuts.contains($0.layer) || ($0.antennaGateArea ?? 0) > 0 || $0.antennaDiffusionArea != nil) }.map {
                .init(id: $0.id, layer: $0.layer, xMin: $0.xMin, yMin: $0.yMin, xMax: $0.xMax, yMax: $0.yMax,
                    netID: $0.netID, antennaGateArea: $0.antennaGateArea, antennaDiffusionArea: $0.antennaDiffusionArea, antennaProcessStep: step)
            }
        } else { records = rectangles }
        return .init(technologyID: geometry.manifestReference.id.description, topCell: snapshot.topCell, unit: "um",
            rectangles: records, rules: [rule], antennaMetadata: rule.kind == .maximumAntennaRatio ? .init(
                gateAreasComplete: true, diffusionAreasComplete: true, processStepsComplete: true, cutConnectivityComplete: true,
                source: geometry.manifestReference.digest.hexadecimalValue) : nil)
    }

    func validateConnectivity(targetNetIDs: Set<String>) throws {
        let units = LayoutUnits(scale: try DatabaseUnitScale(databaseUnitsPerMicrometer: Double(snapshot.unitsPerMicron)))
        var netIDs: [String: UUID] = [:]
        for net in snapshot.nets { netIDs[net.id] = try identity("net:" + net.id) }
        let definitions = geometry.sourceLayers.sorted(by: { $0.key < $1.key }).map { number, source in
            LayoutLayerDefinition(id: .init(name: source.name, purpose: source.type == .cut ? "cut" : "drawing"), displayName: source.name,
                gdsLayer: Int(number), gdsDatatype: 0, color: .init(red: 0, green: 0, blue: 0))
        }
        func layer(_ name: String) throws -> LayoutLayerID {
            guard let value = definitions.first(where: { $0.id.name == name })?.id else { throw PhysicalDesignTechnologyError.invalid("Unknown contact layer.") }; return value
        }
        var viaDefs: [LayoutViaDefinition] = []
        for (name, via) in geometry.vias.sorted(by: { $0.key < $1.key }) {
            guard let cutLayer = geometry.sourceLayers[via.cutLayer]?.name,
                  let lower = geometry.sourceLayers[via.lowerLayer]?.name,
                  let upper = geometry.sourceLayers[via.upperLayer]?.name else { throw PhysicalDesignTechnologyError.invalid("Incomplete named contact layer map.") }
            var layers: [LayoutViaLayerGeometry] = []
            var cutSize: LayoutSize?
            for (number, shapes) in Dictionary(grouping: via.shapes, by: \.layer).sorted(by: { $0.key < $1.key }) {
                guard let sourceName = geometry.sourceLayers[number]?.name else { throw PhysicalDesignTechnologyError.invalid("Unknown fixed source layer.") }
                let bands = try Region(layer: number, polygons: shapes).rectilinearBands(limits: .init(
                    maximumInputEntries: limits.maximumProjectionRecords, maximumEdgeProbes: limits.maximumGeometryProbes,
                    maximumOutputBands: limits.maximumProjectionRecords), isCancelled: { Task.isCancelled })
                let scale = Double(snapshot.unitsPerMicron)
                let rects = bands.map { LayoutRect(origin: .init(x: Double($0.minX) / scale, y: Double($0.minY) / scale),
                    size: .init(width: Double($0.maxX - $0.minX) / scale, height: Double($0.maxY - $0.minY) / scale)) }
                if number == via.cutLayer { cutSize = rects.first?.size }
                layers.append(.init(layer: try layer(sourceName), rects: rects))
            }
            guard let cutSize else { throw PhysicalDesignTechnologyError.invalid("Named contact has no actual cut surface.") }
            viaDefs.append(.init(id: name, cutLayer: try layer(cutLayer), topLayer: try layer(upper), bottomLayer: try layer(lower),
                cutSize: cutSize, enclosure: .init(top: 0, bottom: 0), cutSpacing: 0, layerGeometries: layers))
        }
        var shapes: [LayoutShape] = [], pins: [LayoutPin] = []
        for record in rectangles {
            guard let exact = integerBounds[record.id] else { throw PhysicalDesignTechnologyError.invalid("Missing retained integer source extent.") }
            let scale = Double(snapshot.unitsPerMicron)
            let rect = LayoutRect(origin: .init(x: Double(exact.x) / scale, y: Double(exact.y) / scale),
                size: .init(width: Double(exact.width) / scale, height: Double(exact.height) / scale))
            let sourceLayer = try layer(record.layer)
            let id = try identity(record.id)
            shapes.append(.init(id: id, layer: sourceLayer, netID: record.netID.flatMap { netIDs[$0] }, geometry: .rect(rect)))
            if record.id.hasPrefix("pin:"), record.netID.map({ targetNetIDs.contains($0) }) == true, sourceLayer.purpose != "cut" {
                pins.append(.init(id: try identity("terminal:" + record.id), name: record.id,
                    position: .init(x: Double(exact.x * 2 + exact.width) / (scale * 2), y: Double(exact.y * 2 + exact.height) / (scale * 2)), size: rect.size,
                    layer: sourceLayer, netID: record.netID.flatMap { netIDs[$0] }))
            }
        }
        let cellID = try identity("repair-cell"), cell = LayoutCell(id: cellID, name: snapshot.topCell, shapes: shapes, pins: pins,
            nets: snapshot.nets.map { .init(id: netIDs[$0.id]!, name: $0.id) })
        let document = LayoutDocument(id: try identity("repair-layout"), name: snapshot.topCell, units: units, cells: [cell], topCellID: cellID)
        let tech = LayoutTechDatabase(units: units, grid: 1 / Double(snapshot.unitsPerMicron), layers: definitions, vias: viaDefs, layerRules: [])
        let n = limits.maximumProjectionRecords, probes = limits.maximumGeometryProbes
        let captured = try LayoutConnectivityExtractor().captureConductors(document: document, tech: tech,
            conductiveLayers: Set(definitions.filter { $0.id.purpose != "cut" }.map(\.id)), limits: .init(
                hierarchy: .init(maximumOccurrences: 1, maximumObjects: n, maximumGeometryPoints: probes, maximumDepth: 1),
                decomposition: .init(maximumInputEntries: n, maximumEdgeProbes: probes, maximumOutputBands: n),
                maximumTechnologyRecords: n, maximumFootprints: n, maximumContactProbes: probes))
        guard captured.shortComponentIndices.isEmpty else { throw PhysicalDesignTechnologyError.invalid("Repair introduces a physical short.") }
        let targets = Set(targetNetIDs.compactMap { netIDs[$0] })
        for open in captured.opens where targets.contains(open.net.netID) { throw PhysicalDesignTechnologyError.invalid("Repair target has a physical open.") }
    }

    private func identity(_ value: String) throws -> UUID {
        let digest = try SHA256ContentDigester().digest(data: Data(value.utf8), using: .sha256).hexadecimalValue
        let hex = String(digest.prefix(32)), name = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let value = UUID(uuidString: name) else { throw PhysicalDesignTechnologyError.invalid("Invalid projection identity.") }; return value
    }
}
