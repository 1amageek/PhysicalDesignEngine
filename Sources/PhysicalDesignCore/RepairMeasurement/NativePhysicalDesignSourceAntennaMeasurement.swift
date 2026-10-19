import CircuiteFoundation
import CircuiteFoundationCrypto
import DRCNative
import Foundation

/// Binds exact source facts and candidate geometry; NativeDRC owns every numerical law.
struct NativePhysicalDesignSourceAntennaMeasurement {
    let reference: PhysicalDesignRepairMeasurementReference
    let profile: PhysicalDesignRepairMeasurementProfile
    let source: PhysicalDesignAntennaSourceProjection

    init(reference: PhysicalDesignRepairMeasurementReference, profile: PhysicalDesignRepairMeasurementProfile,
         source: PhysicalDesignAntennaSourceProjection) throws {
        guard profile.schemaVersion == 2, profile.antennaLimitPolicy == .sourceProcessLaws,
              profile.rules.isEmpty, profile.hotspots.isEmpty, !profile.antennaNetIDs.isEmpty,
              Set(profile.antennaNetIDs).count == profile.antennaNetIDs.count,
              profile.processManifest == source.manifestReference, profile.processAssets == source.sources,
              profile.processLayerOrder == source.layers.map(\.sourceName) else {
            throw PhysicalDesignTechnologyError.invalid("Source-process measurement requires exact source order, targets and schema-2 policy without caller rules.")
        }
        guard !source.laws.isEmpty else {
            throw PhysicalDesignTechnologyError.unsupported("Source-process measurement has no applicable source antenna laws.")
        }
        self.reference = reference; self.profile = profile; self.source = source
    }

    private func budget() throws -> NativeSourceAntennaBudget {
        try NativeSourceAntennaBudget(limits: .init(maximumInputRecords: reference.limits.maximumProjectionRecords,
            maximumResults: reference.limits.maximumProjectionRecords, maximumWork: reference.limits.maximumBackendWork,
            maximumStorageEntries: reference.limits.maximumProjectionRecords))
    }

    func candidate(_ snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws -> PhysicalDesignSourceAntennaMeasurementEvidence {
        var budget = try budget()
        var remainingRecords = reference.limits.maximumProjectionRecords - source.recordCount
        let deadline = ContinuousClock.now.advanced(by: .seconds(reference.limits.timeoutSeconds))
        let check = try measure(snapshot, geometry: geometry, phase: "candidate", budget: &budget,
            remainingRecords: &remainingRecords, deadline: deadline)
        return try evidence(snapshot, checks: [check])
    }

    func repair(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
                geometry: PhysicalDesignProcessGeometry,
                makeCandidate: (PhysicalDesignSnapshot, Set<Int>) throws -> PhysicalDesignSnapshot) throws -> NativePhysicalDesignRepairMeasurement.Result {
        var budget = try budget()
        var remainingRecords = reference.limits.maximumProjectionRecords - source.recordCount
        let deadline = ContinuousClock.now.advanced(by: .seconds(reference.limits.timeoutSeconds))
        let before = try measure(input, geometry: geometry, phase: "before", budget: &budget,
            remainingRecords: &remainingRecords, deadline: deadline)
        for id in profile.antennaNetIDs {
            guard before.result.measurements.contains(where: { $0.netID == id && !$0.passed }) else {
                throw PhysicalDesignTechnologyError.invalid("Every source-process repair target requires an actual before violation.")
            }
        }
        let violatedLayers = Set(before.result.measurements.filter { !$0.passed }.map(\.stageLayerID))
        let bypass = Set(try violatedLayers.map { layer -> Int in
            guard let sourceLayer = source.layers.first(where: { $0.layerID == layer }),
                  let number = geometry.sourceLayers.first(where: { $0.value.name == sourceLayer.sourceName })?.key else {
                throw PhysicalDesignTechnologyError.invalid("Source-process violation has no exact routing layer.")
            }
            return Int(number)
        })
        var output = try makeCandidate(input, bypass)
        guard output.routes != input.routes || output.vias != input.vias || output.fills != input.fills || output.cells != input.cells else {
            throw PhysicalDesignTechnologyError.invalid("Source-process repair made no physical change.")
        }
        let measuredAfter = try measure(output, geometry: geometry, phase: "candidate", budget: &budget,
            remainingRecords: &remainingRecords, deadline: deadline)
        guard measuredAfter.result.passed else {
            throw PhysicalDesignTechnologyError.invalid("The candidate retains source-process antenna violations.")
        }
        for id in profile.antennaNetIDs {
            output.antennaRepairs.append(.init(id: "source-measured-\(id)-\(output.antennaRepairs.count)", netID: id,
                strategy: (configuration.repairConstraints ?? .default).antennaStrategy.rawValue,
                previousRatio: nil, resultingRatio: nil, ratioStatus: .sourceProcessLawMeasurements,
                satisfiedRuleIDs: measuredAfter.input.rules.map(\.id)))
            if let index = output.nets.firstIndex(where: { $0.id == id }) { output.nets[index].antennaRatio = nil }
        }
        output.implementationState?.repairProofs.removeAll()
        output.implementationState?.routingEvidence = nil
        for index in output.clockTrees.indices { output.clockTrees[index].timingEstimate = nil }
        var state = output.implementationState ?? .init()
        state.repairProofs.append(.init(stage: PhysicalDesignStage.antennaRepair.rawValue,
            strategy: "source_process_law_remeasurement", targetIDs: profile.antennaNetIDs,
            violationsBefore: before.result.measurements.filter { !$0.passed }.count, violationsAfter: 0,
            verified: true, details: ["exact_source_process_laws", "complete_port_gate_diffusion_identity", "direct_native_numeric_measurement_and_connectivity"]))
        output.implementationState = state
        let after = PhysicalDesignSourceAntennaMeasurementEvidence.Check(phase: "candidate", snapshotDigest: try digest(output),
            terminalDeclarations: measuredAfter.terminalDeclarations, nonConductorRecords: measuredAfter.nonConductorRecords, input: measuredAfter.input, result: measuredAfter.result)
        return .init(snapshot: output, evidence: nil, sourceAntennaEvidence: try evidence(output, checks: [before, after]))
    }

    private func measure(_ snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry, phase: String,
                         budget: inout NativeSourceAntennaBudget, remainingRecords: inout Int,
                         deadline: ContinuousClock.Instant) throws -> PhysicalDesignSourceAntennaMeasurementEvidence.Check {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw PhysicalDesignTechnologyError.invalid("Source antenna deadline exhausted.") }
        let projection = try PhysicalDesignRepairProjection(snapshot: snapshot, geometry: geometry,
            profile: profile, limits: reference.limits, requireGateFacts: false)
        let lowered = try lowerInput(snapshot, geometry: geometry, projection: projection, remainingRecords: &remainingRecords)
        var connectivityTargets = Set(profile.antennaNetIDs)
        if let protection = profile.protection { connectivityTargets.formUnion(protection.otherPinNetIDs.values) }
        try projection.validateConnectivity(targetNetIDs: connectivityTargets)
        let input = lowered.input
        let bytes = try PhysicalDesignJSONCodec().encode(input)
        guard bytes.count <= reference.limits.maximumInputBytes else {
            throw PhysicalDesignTechnologyError.invalid("Source antenna input-byte ceiling exhausted.")
        }
        let result: NativeSourceAntennaResult
        do {
            result = try NativeSourceAntennaEvaluator().evaluate(input, budget: &budget,
                isCancelled: { Task.isCancelled || ContinuousClock.now >= deadline })
        } catch NativeSourceAntennaError.cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw PhysicalDesignTechnologyError.invalid("Source antenna deadline exhausted.")
        } catch NativeSourceAntennaError.unsupported(let reason) {
            throw PhysicalDesignTechnologyError.unsupported(reason)
        } catch {
            throw PhysicalDesignTechnologyError.invalid("Source antenna evaluation refused: \(error)")
        }
        guard !result.measurements.isEmpty,
              input.rules.allSatisfy({ rule in input.targetNetIDs.allSatisfy { net in
                  result.measurements.contains { $0.ruleID == rule.id && $0.netID == net }
              } }) else {
            throw PhysicalDesignTechnologyError.unsupported("Source antenna numeric prefix coverage is incomplete.")
        }
        let declarations = try input.terminals.map { terminal -> PhysicalDesignSourceAntennaMeasurementEvidence.TerminalDeclaration in
            guard let pin = snapshot.pins.first(where: { $0.id == terminal.id }), let cellID = pin.cellID,
                  let cell = snapshot.cells.first(where: { $0.id == cellID }),
                  let fact = source.terminals.first(where: { $0.masterName == cell.master && $0.pinName == pin.name }) else {
                throw PhysicalDesignTechnologyError.invalid("Source terminal declaration disappeared.")
            }
            return .init(pinID: pin.id, masterName: cell.master, pinName: pin.name, source: fact.source,
                rawGateAreaSquareMicrons: fact.rawGateAreaSquareMicrons,
                rawDiffusionAreaSquareMicrons: fact.rawDiffusionAreaSquareMicrons,
                reportedDiffusionAreaSquareMicrons: fact.reportedDiffusionAreaSquareMicrons,
                diffusionOrigin: diffusionOrigin(fact))
        }
        return .init(phase: phase, snapshotDigest: try digest(snapshot), terminalDeclarations: declarations, nonConductorRecords: lowered.nonConductorRecords, input: input, result: result)
    }

    private func lowerInput(_ snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry,
                            projection: PhysicalDesignRepairProjection, remainingRecords: inout Int) throws -> (input: NativeSourceAntennaInput, nonConductorRecords: [PhysicalDesignSourceAntennaMeasurementEvidence.NonConductorRecord]) {
        func sourceLayer(_ name: String) throws -> PhysicalDesignAntennaSourceProjection.Layer {
            guard let layer = source.layers.first(where: { $0.sourceName == name }) else {
                throw PhysicalDesignTechnologyError.invalid("Unbound source antenna layer.")
            }
            return layer
        }
        var layers: [NativeSourceAntennaInput.Layer] = []
        var rectangles: [NativeSourceAntennaInput.Rectangle] = []
        var nonConductors: [PhysicalDesignSourceAntennaMeasurementEvidence.NonConductorRecord] = []
        var terminals: [NativeSourceAntennaInput.Terminal] = []
        var rules: [NativeSourceAntennaInput.Rule] = []
        func admit() throws {
            try Task.checkCancellation()
            guard remainingRecords > 0 else { throw PhysicalDesignTechnologyError.invalid("Cumulative source antenna projection record ceiling exhausted.") }
            remainingRecords -= 1
        }
        for layer in source.layers {
            try admit()
            if !layer.isCut { layers.append(.init(id: layer.layerID, kind: .routing)); continue }
            let stacks = try geometry.vias.values.filter { geometry.sourceLayers[$0.cutLayer]?.name == layer.sourceName }.map { via -> [String] in
                guard let lowerName = geometry.sourceLayers[via.lowerLayer]?.name, let upperName = geometry.sourceLayers[via.upperLayer]?.name else {
                    throw PhysicalDesignTechnologyError.invalid("Unbound source cut connection.")
                }
                return [try sourceLayer(lowerName).layerID, try sourceLayer(upperName).layerID]
            }
            let pairs = Set(stacks)
            guard pairs.count == 1, let pair = pairs.first else {
                throw PhysicalDesignTechnologyError.unsupported("A source cut requires one exact fixed-VIA layer connection.")
            }
            layers.append(.init(id: layer.layerID, kind: .cut(lowerLayerID: pair[0], upperLayerID: pair[1])))
        }
        for record in projection.rectangles {
            try admit()
            guard let bounds = projection.integerBounds[record.id], let sourceID = projection.sourceIDByRecordID[record.id] else {
                throw PhysicalDesignTechnologyError.invalid("Missing exact source shape identity or extent.")
            }
            let matches = geometry.sourceLayers.filter { $0.value.name == record.layer }
            guard matches.count == 1, let mapped = matches.first, let layer = geometry.layers[mapped.key] else {
                throw PhysicalDesignTechnologyError.invalid("Unmapped or ambiguous source antenna shape layer.")
            }
            let nonConductorKind: PhysicalDesignSourceAntennaMeasurementEvidence.NonConductorRecord.SourceKind?
            switch mapped.value.type {
            case .routing, .cut: nonConductorKind = nil
            case .masterslice: nonConductorKind = .masterslice
            case .overlap: nonConductorKind = .overlap
            case .implant: nonConductorKind = .implant
            }
            if let nonConductorKind {
                guard record.netID.map({ !profile.antennaNetIDs.contains($0) }) ?? true else {
                    throw PhysicalDesignTechnologyError.unsupported("A target terminal PORT contains a nonconductor source layer.")
                }
                nonConductors.append(.init(recordID: record.id, sourceID: sourceID, layerID: layer.layerID,
                    sourceLayerName: record.layer, sourceKind: nonConductorKind, netID: record.netID,
                    minX: bounds.x, minY: bounds.y, maxX: bounds.maxX, maxY: bounds.maxY))
                continue
            }
            rectangles.append(.init(id: record.id, layerID: try sourceLayer(record.layer).layerID, netID: record.netID,
                minX: bounds.x, minY: bounds.y, maxX: bounds.maxX, maxY: bounds.maxY))
        }
        for id in profile.antennaNetIDs {
            guard let net = snapshot.nets.first(where: { $0.id == id }), !net.pinIDs.isEmpty,
                  Set(net.pinIDs) == Set(snapshot.pins.filter { $0.netID == id }.map(\.id)) else {
                throw PhysicalDesignTechnologyError.invalid("Source antenna target terminal coverage is incomplete.")
            }
        }
        for pin in snapshot.pins where pin.netID.map({ profile.antennaNetIDs.contains($0) }) == true {
            try admit()
            guard let cellID = pin.cellID, let cell = snapshot.cells.first(where: { $0.id == cellID }),
                  let fact = source.terminals.first(where: { $0.masterName == cell.master && $0.pinName == pin.name }),
                  let net = pin.netID else {
                throw PhysicalDesignTechnologyError.unsupported("A target terminal lacks source gate coverage or has an opaque top PORT.")
            }
            if case .missingRequiredGate = fact.gateCoverage {
                throw PhysicalDesignTechnologyError.unsupported("A target terminal lacks a required source gate declaration.")
            }
            let records = projection.rectangles.filter { projection.sourceIDByRecordID[$0.id] == "pin:" + pin.id }.map(\.id)
            guard !records.isEmpty else { throw PhysicalDesignTechnologyError.invalid("A target terminal has no complete PORT identity.") }
            terminals.append(.init(id: pin.id, netID: net, portRecordIDs: records,
                gateAreaSquareMicrons: fact.rawGateAreaSquareMicrons, diffusionAreaSquareMicrons: fact.reportedDiffusionAreaSquareMicrons))
        }
        for law in source.laws {
            try admit()
            let basis: NativeSourceAntennaInput.Rule.Basis
            switch law.basis { case .surface: basis = .surface; case .sidewall: basis = .sidewall; case .cutArea: basis = .cutArea }
            let limit: NativeSourceAntennaInput.RatioLimit
            switch law.ratio {
            case .scalar(let value): limit = .scalar(value)
            case .piecewiseLinear(let points):
                var retained: [NativeSourceAntennaInput.PWLPoint] = []
                for point in points { try admit(); retained.append(.init(diffusionAreaSquareMicrons: point.diffusionAreaSquareMicrons, ratio: point.ratio)) }
                limit = .pwl(retained)
            }
            let id = "\(law.source.digest.hexadecimalValue):\(law.layerID):\(law.sourceStatementIndex):\(basis.rawValue)"
            rules.append(.init(id: id, layerID: law.layerID, basis: basis, thicknessMicrons: law.thicknessMicrons, limit: limit))
        }
        guard let units = UInt64(exactly: snapshot.unitsPerMicron) else { throw PhysicalDesignTechnologyError.invalid("Invalid source antenna database units.") }
        return (.init(unitsPerMicron: units, layers: layers, rectangles: rectangles, terminals: terminals,
            targetNetIDs: profile.antennaNetIDs.sorted(), rules: rules), nonConductors)
    }

    private func diffusionOrigin(_ terminal: PhysicalDesignAntennaSourceProjection.Terminal) -> String {
        switch terminal.diffusionOrigin {
        case .explicit: return "explicit"
        case .omittedUnqualifiedZero: return "omitted_unqualified_zero"
        }
    }

    private func digest(_ snapshot: PhysicalDesignSnapshot) throws -> ContentDigest {
        try SHA256ContentDigester().digest(data: PhysicalDesignJSONCodec().encode(snapshot), using: .sha256)
    }

    private func evidence(_ snapshot: PhysicalDesignSnapshot, checks: [PhysicalDesignSourceAntennaMeasurementEvidence.Check]) throws -> PhysicalDesignSourceAntennaMeasurementEvidence {
        .init(profile: reference.artifact.reference, processManifest: source.manifestReference, processAssets: source.sources,
            candidateSnapshotDigest: try digest(snapshot), targetNetIDs: profile.antennaNetIDs.sorted(),
            coverage: checks.last?.result.passed == true ? .clean : .violated, checks: checks)
    }
}
