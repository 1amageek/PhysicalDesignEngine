import Foundation
import CircuiteFoundationFoundation
import CircuiteFoundationCrypto
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutIR
import MaskGeometry
import PEXCore
import PEXNative

/// Projects admitted physical conductors into the lower geometry/mesh owners.
struct PhysicalDesignClockConductorProjection {
    let electrodes: NativePEXElectrodeNetwork
    let pinIndices: [String: Int]

    init(snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry,
         characterization: PhysicalDesignClockCharacterization, selectedPins: Set<String>) throws {
        let model = characterization.model, policy = model.numerics
        let units = LayoutUnits(scale: try DatabaseUnitScale(databaseUnitsPerMicrometer: Double(snapshot.unitsPerMicron)))
        let scale = Double(snapshot.unitsPerMicron)
        var layerIDs: [Int16: LayoutLayerID] = [:], layerNames: [LayoutLayerID: String] = [:]
        var definitions: [LayoutLayerDefinition] = []
        for (number, source) in geometry.layers.sorted(by: { $0.key < $1.key }) {
            guard let name = characterization.technology.logicalToPhysicalLayerMap[source.layerID], !name.isEmpty,
                  let sourceLayer = geometry.sourceLayers[number] else { throw Self.invalid("exact RC layer mapping") }
            let layer = LayoutLayerID(name: source.layerID, purpose: sourceLayer.type == .cut ? "cut" : "drawing")
            layerIDs[number] = layer; layerNames[layer] = name
            definitions.append(.init(id: layer, displayName: source.layerID, gdsLayer: Int(number), gdsDatatype: 0,
                                     color: LayoutColor(red: 0, green: 0, blue: 0)))
        }
        func layer(_ number: Int16) throws -> LayoutLayerID {
            guard let value = layerIDs[number] else { throw Self.invalid("source conductor layer") }; return value
        }
        func point(_ p: IRPoint) -> LayoutPoint { .init(x: Double(p.x) / scale, y: Double(p.y) / scale) }
        func rectangle(_ inputPoints: [IRPoint]) throws -> LayoutRect {
            let points = inputPoints.first == inputPoints.last ? Array(inputPoints.dropLast()) : inputPoints
            guard points.count == 4, let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
                  let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max(), x0 < x1, y0 < y1,
                  Set(points).count == 4, points.allSatisfy({ ($0.x == x0 || $0.x == x1) && ($0.y == y0 || $0.y == y1) }) else {
                throw Self.invalid("bounded electrode profile requires a single rectangular PORT")
            }
            return .init(origin: .init(x: Double(x0) / scale, y: Double(y0) / scale),
                         size: .init(width: Double(x1 - x0) / scale, height: Double(y1 - y0) / scale))
        }
        var shapes: [LayoutShape] = [], pins: [LayoutPin] = [], vias: [LayoutVia] = [], viaDefinitions: [LayoutViaDefinition] = []
        var pinByUUID: [UUID: String] = [:], records = 0
        func admit(_ count: Int = 1) throws {
            try Task.checkCancellation()
            let sum = records.addingReportingOverflow(count)
            guard count >= 0, !sum.overflow, sum.partialValue <= policy.maximumProjectionRecords else { throw Self.invalid("projection record budget") }
            records = sum.partialValue
        }
        let netIDs = try Dictionary(uniqueKeysWithValues: snapshot.nets.map { ($0.id, try Self.identity("net:" + $0.id)) })
        for cell in snapshot.cells {
            let master = try geometry.requireMaster(cell.master)
            for name in master.pins.keys.sorted() {
                let matching = snapshot.pins.filter { $0.cellID == cell.id && $0.name == name }
                guard matching.count <= 1 else { throw Self.invalid("ambiguous master pin") }
                let canonical = matching.first
                let ports = try geometry.pinShapes(master: cell.master, pin: name, orientation: cell.orientation, x: cell.x, y: cell.y)
                for (index, port) in ports.enumerated() {
                    try admit(port.points.count + 1)
                    guard geometry.sourceLayers[port.layer]?.type != .cut else { throw Self.invalid("PORT cut without an explicit fixed via") }
                    shapes.append(.init(id: try Self.identity("port:\(cell.id):\(name):\(index)"), layer: try layer(port.layer),
                        netID: canonical?.netID.flatMap { netIDs[$0] }, geometry: .polygon(.init(points: port.points.map(point)))))
                }
                if let canonical, selectedPins.contains(canonical.id) {
                    guard let access = canonical.accessLayer, let number = Int16(exactly: access) else { throw Self.invalid("pin access layer") }
                    let accessPorts = ports.filter { $0.layer == number }
                    guard accessPorts.count == 1, let port = accessPorts.first else { throw Self.invalid("electrode PORT multiplicity") }
                    let rect = try rectangle(port.points), id = try Self.identity("pin:" + canonical.id)
                    try admit()
                    pins.append(.init(id: id, name: canonical.id,
                        position: .init(x: rect.origin.x + rect.size.width / 2, y: rect.origin.y + rect.size.height / 2),
                        size: rect.size, layer: try layer(number), netID: canonical.netID.flatMap { netIDs[$0] }, role: .signal))
                    pinByUUID[id] = canonical.id
                }
            }
        }
        guard pins.count == selectedPins.count else { throw Self.invalid("source-bound cell pin coverage") }
        for route in snapshot.routes {
            for segment in route.segments {
                try admit()
                guard let width = segment.widthDBU, width > 0, width.isMultiple(of: 2), let number = Int16(exactly: segment.layer),
                      segment.x1 == segment.x2 || segment.y1 == segment.y2 else { throw Self.invalid("exact full-width rectilinear route") }
                func add(_ a: Int64, _ b: Int64) throws -> Int64 {
                    let v = a.addingReportingOverflow(b); guard !v.overflow else { throw Self.invalid("conductor arithmetic") }; return v.partialValue
                }
                let half = width / 2
                let x0 = try add(min(segment.x1, segment.x2), -half), x1 = try add(max(segment.x1, segment.x2), half)
                let y0 = try add(min(segment.y1, segment.y2), -half), y1 = try add(max(segment.y1, segment.y2), half)
                let rect = LayoutRect(origin: .init(x: Double(x0) / scale, y: Double(y0) / scale),
                    size: .init(width: Double(x1 - x0) / scale, height: Double(y1 - y0) / scale))
                shapes.append(.init(id: try Self.identity("route:" + segment.id), layer: try layer(number), netID: netIDs[route.netID], geometry: .rect(rect)))
            }
        }
        for (name, source) in geometry.vias.sorted(by: { $0.key < $1.key }) {
            try admit(source.shapes.count)
            let grouped = Dictionary(grouping: source.shapes, by: \.layer)
            let geometries = try grouped.keys.sorted().map { number in
                LayoutViaLayerGeometry(layer: try layer(number), rects: try grouped[number]!.map { try rectangle($0.points) })
            }
            guard let cut = grouped[source.cutLayer]?.first else { throw Self.invalid("fixed cut source") }
            let cutRect = try rectangle(cut.points)
            viaDefinitions.append(.init(id: name, cutLayer: try layer(source.cutLayer), topLayer: try layer(source.upperLayer),
                bottomLayer: try layer(source.lowerLayer), cutSize: cutRect.size, enclosure: .init(top: 0, bottom: 0),
                cutSpacing: Double(geometry.cutSpacings[source.cutLayer] ?? 0) / scale, layerGeometries: geometries))
        }
        for source in snapshot.vias {
            try admit()
            guard let name = source.master, geometry.vias[name] != nil else { throw Self.invalid("exact fixed via identity") }
            vias.append(.init(id: try Self.identity("via:" + source.id), viaDefinitionID: name,
                position: .init(x: Double(source.x) / scale, y: Double(source.y) / scale), netID: netIDs[source.netID]))
        }
        // Fill is retained physical metal. Power/special structures are rejected by the source router.
        for fill in snapshot.fills {
            try admit()
            guard let number = Int16(exactly: fill.layer) else { throw Self.invalid("fill layer") }
            shapes.append(.init(id: try Self.identity("fill:" + fill.id), layer: try layer(number), geometry: .rect(.init(
                origin: .init(x: Double(fill.geometry.x) / scale, y: Double(fill.geometry.y) / scale),
                size: .init(width: Double(fill.geometry.width) / scale, height: Double(fill.geometry.height) / scale)))))
        }
        let cellID = try Self.identity("clock-projection"), cell = LayoutCell(id: cellID, name: snapshot.topCell,
            shapes: shapes, vias: vias, pins: pins, nets: snapshot.nets.map { .init(id: netIDs[$0.id]!, name: $0.id) })
        let document = LayoutDocument(id: try Self.identity("clock-document"), name: snapshot.topCell, units: units, cells: [cell], topCellID: cellID)
        let tech = LayoutTechDatabase(units: units, grid: 1 / scale, layers: definitions, vias: viaDefinitions, layerRules: [])
        let n = policy.maximumProjectionRecords, probes = policy.maximumGeometryProbes
        let capture = try LayoutConnectivityExtractor().captureConductors(document: document, tech: tech,
            conductiveLayers: Set(definitions.filter { $0.id.purpose != "cut" }.map(\.id)), limits: .init(
                hierarchy: .init(maximumOccurrences: 1, maximumObjects: n, maximumGeometryPoints: probes, maximumDepth: 1),
                decomposition: .init(maximumInputEntries: n, maximumEdgeProbes: probes, maximumOutputBands: n),
                maximumTechnologyRecords: n, maximumFootprints: n, maximumContactProbes: probes))
        guard capture.shortComponentIndices.isEmpty else { throw Self.invalid("physical short in clock projection") }
        var indices: [String: Int] = [:], bindings: [NativePEXElectrodeBinding] = []
        let cells = Dictionary(uniqueKeysWithValues: snapshot.cells.map { ($0.id, $0) })
        let canonicalPins = Dictionary(uniqueKeysWithValues: snapshot.pins.map { ($0.id, $0) })
        let multiplier = capture.coordinateUnits.scale.databaseUnitsPerMicrometer / scale
        guard let integerMultiplier = Int64(exactly: multiplier), integerMultiplier > 0 else { throw Self.invalid("capture electrode coordinate scale") }
        for (index, pin) in capture.pins.enumerated() {
            try Task.checkCancellation()
            guard let id = pinByUUID[capture.hierarchy.pins[pin.sourcePinIndex].id], let canonical = canonicalPins[id],
                  let cellID = canonical.cellID, let cell = cells[cellID], let netID = canonical.netID,
                  let electrode = model.electrodes.first(where: { $0.master == cell.master && $0.pin == canonical.name }),
                  pin.componentIndices.count == 1 else { throw Self.invalid("electrode identity/open/coverage") }
            let master = try geometry.requireMaster(cell.master)
            func project(_ x: Int64, _ y: Int64) throws -> IRPoint {
                guard let px = Int32(exactly: x), let py = Int32(exactly: y) else { throw Self.invalid("electrode coordinate arithmetic") }
                return try geometry.projectMasterPoint(.init(x: px, y: py), master: master,
                    orientation: cell.orientation, x: cell.x, y: cell.y)
            }
            func scaled(_ value: Int32) throws -> Int32 {
                let v = Int64(value).multipliedReportingOverflow(by: integerMultiplier)
                guard !v.overflow, let result = Int32(exactly: v.partialValue) else { throw Self.invalid("electrode scale arithmetic") }; return result
            }
            let faces = try electrode.faces.map { face -> NativePEXElectrodeFace in
                let alongX = face.side == .minY || face.side == .maxY
                let a = try project(alongX ? Int64(face.begin) : Int64(face.coordinate), alongX ? Int64(face.coordinate) : Int64(face.begin))
                let b = try project(alongX ? Int64(face.end) : Int64(face.coordinate), alongX ? Int64(face.coordinate) : Int64(face.end))
                let dx: Int64 = face.side == .minX ? -1 : face.side == .maxX ? 1 : 0
                let dy: Int64 = face.side == .minY ? -1 : face.side == .maxY ? 1 : 0
                let normal = try project((alongX ? Int64(face.begin) : Int64(face.coordinate)) + dx,
                                         (alongX ? Int64(face.coordinate) : Int64(face.begin)) + dy)
                let side: NativePEXElectrodeFace.Side = normal.x < a.x ? .minX : normal.x > a.x ? .maxX : normal.y < a.y ? .minY : .maxY
                let horizontal = a.y == b.y
                return .init(side: side, coordinate: try scaled(horizontal ? a.y : a.x),
                    begin: try scaled(horizontal ? min(a.x, b.x) : min(a.y, b.y)), end: try scaled(horizontal ? max(a.x, b.x) : max(a.y, b.y)))
            }
            indices[id] = index
            bindings.append(.init(pinIndex: index, terminal: .init(netName: .init(netID), nodeName: .init(id)), faces: faces))
        }
        let network = try RectilinearPEXCalculator().calculate(snapshot: capture, technology: characterization.technology,
            corner: characterization.corner, layerNames: layerNames, maximumCellSpanDatabaseUnits: policy.maximumCellSpanDBU,
            limits: policy.extraction)
        electrodes = try RectilinearPEXElectrodeBuilder().build(network: network, bindings: bindings, limits: policy.electrodes)
        pinIndices = indices
    }
    private static func identity(_ value: String) throws -> UUID {
        let digest = try SHA256ContentDigester().digest(data: Data(value.utf8), using: .sha256).hexadecimalValue
        let hex = String(digest.prefix(32))
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: value)!
    }
    private static func invalid(_ reason: String) -> PhysicalDesignClockTimingModelError { .invalidModel(reason) }
}
