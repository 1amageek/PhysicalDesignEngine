import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import PEXCore
import PEXParsers
import TimingCore

struct NativePhysicalDesignPlacementRCProjection: Sendable {
    struct Result: Sendable {
        let network: ParasiticIR
        let spef: Data
        let reference: ArtifactReference
        let snapshotDigest: ContentDigest
        let reservations: [LibertySourceStorageReservation]
    }

    let profile: PhysicalDesignPlacementTimingProfile
    private let units: Int
    private let width: Double
    private let sheetResistance: Double
    private let areaCapacitance: Double
    private let edgeCapacitance: Double

    init(profile: PhysicalDesignPlacementTimingProfile, inputs: PhysicalDesignProcessInputs,
         geometry: PhysicalDesignProcessGeometry) throws {
        guard profile.isSourceBoundSequential, profile.manifest == geometry.manifestReference,
              geometry.unitsPerMicron > 0, profile.wireWidthDBU > 0,
              Int(exactly: Double(geometry.unitsPerMicron)) == geometry.unitsPerMicron,
              Int64(exactly: Double(profile.wireWidthDBU)) == profile.wireWidthDBU,
              let corner = inputs.manifest.corners.first(where: { $0.cornerID == profile.cornerID }),
              corner.rcCorner == profile.rcCornerID, corner.assetIDs.contains(profile.capacitanceAssetID),
              let document = inputs.technologyViews[profile.capacitanceAssetID],
              let index = Int16(exactly: profile.wireLayer), let layer = geometry.sourceLayers[index],
              document.layers.contains(layer), layer.type == .routing,
              let resistancePrecision = document.unitDeclarations.resistanceOhms,
              resistancePrecision.isFinite, resistancePrecision > 0,
              let capacitancePrecision = document.unitDeclarations.capacitancePicofarads,
              capacitancePrecision.isFinite, capacitancePrecision > 0,
              let resistance = layer.resistance, resistance.isFinite, resistance > 0,
              let area = layer.capacitance, area.isFinite, area >= 0,
              let edge = layer.edgeCapacitance, edge.isFinite, edge >= 0, (area + edge).isFinite, area + edge > 0,
              let minimum = layer.minwidth ?? layer.width, minimum.isFinite, minimum > 0 else {
            throw PhysicalDesignPlacementTimingError.invalidProfile("Source RC projection requires exact routing sheet resistance, capacitance, units and corner")
        }
        let width = Double(profile.wireWidthDBU) / Double(geometry.unitsPerMicron)
        guard width.isFinite, width > 0, width >= minimum,
              layer.maxwidth == nil || (layer.maxwidth!.isFinite && width <= layer.maxwidth!) else {
            throw PhysicalDesignPlacementTimingError.invalidProfile("Source RC width is outside its declared material range")
        }
        self.profile = profile; units = geometry.unitsPerMicron; self.width = width
        sheetResistance = resistance; areaCapacitance = area; edgeCapacitance = edge
    }

    func project(_ snapshot: PhysicalDesignSnapshot, graph: TimingDesign,
                 budget: NativePhysicalDesignPlacementTimingBudget) throws -> Result {
        try budget.check()
        guard snapshot.unitsPerMicron == units, graph.topDesignName == snapshot.topCell,
              snapshot.processManifest == profile.manifest else {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("Source RC projection differs from the classified candidate")
        }
        var terminalCount = 0
        var maximumNameBytes = max(snapshot.topCell.utf8.count, 20)
        for net in snapshot.nets {
            try budget.chargeWork(1)
            maximumNameBytes = max(maximumNameBytes, net.id.utf8.count)
            try budget.chargeWork(UInt64(graph.nets.count))
            if graph.nets.contains(where: { $0.name == net.id }) {
                terminalCount = try added(terminalCount, net.pinIDs.count)
            }
        }
        for pin in snapshot.pins {
            try budget.chargeWork(1)
            maximumNameBytes = max(maximumNameBytes,
                try added(try added(pin.cellID?.utf8.count ?? 0, pin.name.utf8.count), 1))
        }
        guard terminalCount >= graph.nets.count else {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("A signal RC net has no source terminal")
        }
        let branches = terminalCount - graph.nets.count
        let elementsBound = try multiplied(branches, 3)
        let records = try added(try added(terminalCount, elementsBound), try added(graph.nets.count, 1))
        // JSON escaping (6), hex annotation (2), scoped tokens and repeated endpoints fit 64 name bytes per record.
        let outputBound = try added(4096, try multiplied(records, try added(256, try multiplied(64, maximumNameBytes))))
        let pinStorage = try multiplied(snapshot.pins.count,
            try added(MemoryLayout<PhysicalDesignSnapshot.Pin>.stride, MemoryLayout<String>.stride))
        let payloadBound = try added(pinStorage,
            try added(try multiplied(records, 256), try multiplied(terminalCount, maximumNameBytes)))
        let writerWork = try added(outputBound,
            try added(try multiplied(records, records), try multiplied(graph.nets.count, elementsBound)))
        try budget.chargeWork(UInt64(writerWork))
        let networkReservation = try budget.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(payloadBound))
        var pins: [String: PhysicalDesignSnapshot.Pin] = [:]
        for pin in snapshot.pins {
            try budget.chargeWork(1)
            guard pins.updateValue(pin, forKey: pin.id) == nil else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Duplicate source RC pin identity")
            }
        }
        var nets: [ParasiticNet] = []
        var elements: [ParasiticElement] = []
        for graphNet in graph.nets {
            try budget.check()
            var physical: PhysicalDesignSnapshot.Net?
            for candidate in snapshot.nets {
                try budget.chargeWork(1)
                if candidate.id == graphNet.name {
                    guard physical == nil else { throw PhysicalDesignPlacementTimingError.logicalMismatch("Duplicate source RC net") }
                    physical = candidate
                }
            }
            guard let physical, !physical.pinIDs.isEmpty else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Source RC signal net is missing")
            }
            var driver: PhysicalDesignSnapshot.Pin?
            var nodes: [ParasiticNode] = []
            var names = Set<String>()
            let netName = NetName(graphNet.name)
            for id in physical.pinIDs {
                try budget.chargeWork(1)
                guard let pin = pins[id], pin.netID == graphNet.name,
                      pin.direction == "input" || pin.direction == "output" else {
                    throw PhysicalDesignPlacementTimingError.logicalMismatch("Source RC terminal incidence or direction is unavailable")
                }
                let name = terminalName(pin)
                guard names.insert(name).inserted else {
                    throw PhysicalDesignPlacementTimingError.logicalMismatch("Noninjective source RC terminal name")
                }
                nodes.append(.init(name: .init(name), kind: .pin,
                    instancePath: pin.cellID.map(InstancePath.init), coordinate: nil))
                if pin.cellID == nil ? pin.direction == "input" : pin.direction == "output" {
                    guard driver == nil else { throw PhysicalDesignPlacementTimingError.logicalMismatch("Source RC net has multiple drivers") }
                    driver = pin
                }
            }
            guard let driver else { throw PhysicalDesignPlacementTimingError.logicalMismatch("Source RC net has no physical driver") }
            let from = NodeRef(netName: netName, nodeName: .init(terminalName(driver)))
            var totalR = 0.0, totalC = 0.0
            for (index, id) in physical.pinIDs.enumerated() where id != driver.id {
                try budget.chargeWork(1)
                guard let sink = pins[id] else { throw PhysicalDesignPlacementTimingError.logicalMismatch("Source RC sink is missing") }
                let lengthDBU = try added(try distance(driver.x, sink.x), try distance(driver.y, sink.y))
                guard Int64(exactly: Double(lengthDBU)) == Int64(exactly: lengthDBU) else {
                    throw PhysicalDesignPlacementTimingError.invalidProfile("Source RC distance is not exactly representable")
                }
                let length = Double(lengthDBU) / Double(units)
                let resistance = sheetResistance * (length / width)
                let capacitance = lengthDBU == 0 ? 0 :
                    (length * width * areaCapacitance + 2 * (length + width) * edgeCapacitance) * 1e-12
                guard resistance.isFinite, capacitance.isFinite,
                      lengthDBU == 0 || (resistance > 0 && capacitance > 0 && capacitance / 2 > 0),
                      (totalR + resistance).isFinite, (totalC + capacitance).isFinite else {
                    throw PhysicalDesignPlacementTimingError.invalidProfile("Source RC branch is outside representable numeric range")
                }
                let to = NodeRef(netName: netName, nodeName: .init(terminalName(sink)))
                let prefix = "branch\(nets.count)_\(index)"
                elements.append(.init(id: prefix + "R", kind: .resistor, nodeA: from, nodeB: to,
                    value: resistance, source: .calculated))
                if lengthDBU > 0 {
                    elements.append(.init(id: prefix + "A", kind: .capacitor, nodeA: from, nodeB: nil,
                        value: capacitance / 2, source: .calculated))
                    elements.append(.init(id: prefix + "B", kind: .capacitor, nodeA: to, nodeB: nil,
                        value: capacitance / 2, source: .calculated))
                }
                totalR += resistance; totalC += capacitance
            }
            nets.append(.init(name: netName, nodes: nodes, totalGroundCapF: totalC,
                totalCouplingCapF: 0, totalResistanceOhm: totalR))
        }
        guard nets.count == graph.nets.count, elements.count <= elementsBound else {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("Source RC projection exceeded its admitted inventory")
        }
        let network = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: .init(profile.rcCornerID),
            units: .canonical, nets: nets, elements: elements,
            metadata: ["designName": snapshot.topCell, "model": profile.model, "origin": "preRouteProjected"])
        let spef: Data
        let outputReservation: LibertySourceStorageReservation
        do {
            // Retain logical space for writer lines, joined String, annotation and UTF-8 output during conversion.
            let temporary = try budget.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(try multiplied(outputBound, 4)))
            let encoded: (Data, LibertySourceStorageReservation) = try withExtendedLifetime(temporary) {
                let writer = SPEFWriter(options: .init(designName: snapshot.topCell, program: "PhysicalDesignEngine",
                    terminalTokenProfile: .canonical))
                let text: String
                do { text = try writer.write(network) }
                catch let error as SPEFWriterError { throw PhysicalDesignPlacementTimingError.parasiticProjection(error) }
                guard text.utf8.count <= outputBound else {
                    throw PhysicalDesignPlacementTimingError.resourceLimit("Source RC writer exceeded its admitted encoded-byte bound")
                }
                let bytes = Data(text.utf8)
                try budget.chargeInput(UInt64(bytes.count))
                let reservation = try budget.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(bytes.count))
                try budget.check()
                return (bytes, reservation)
            }
            spef = encoded.0; outputReservation = encoded.1
        }
        let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: spef, using: .sha256),
            byteCount: UInt64(spef.count), descriptor: .init(role: .input, kind: .parasitics, format: .spef))
        return .init(network: network, spef: spef, reference: reference,
            snapshotDigest: try PhysicalDesignPlacementTimingEvidence.geometryDigest(snapshot),
            reservations: [networkReservation, outputReservation])
    }

    private func terminalName(_ pin: PhysicalDesignSnapshot.Pin) -> String {
        pin.cellID.map { $0 + ":" + pin.name } ?? pin.name
    }
    private func distance(_ a: Int64, _ b: Int64) throws -> Int {
        let delta = max(a, b).subtractingReportingOverflow(min(a, b))
        guard !delta.overflow, let value = Int(exactly: delta.partialValue) else {
            throw PhysicalDesignPlacementTimingError.invalidProfile("Source RC coordinate difference overflow")
        }
        return value
    }
    private func added(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw PhysicalDesignPlacementTimingError.resourceLimit("Source RC size overflow") }
        return result.partialValue
    }
    private func multiplied(_ a: Int, _ b: Int) throws -> Int {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw PhysicalDesignPlacementTimingError.resourceLimit("Source RC size overflow") }
        return result.partialValue
    }
}
