import Foundation
import CircuiteFoundationCrypto
import DRCCore
import DRCNative
import LayoutIR
import MaskGeometry

/// Uses existing rule and connectivity owners for one unpublished repair candidate.
struct NativePhysicalDesignRepairMeasurement: Sendable {
    struct Evaluation { let layout: NativeDRCLayout; let result: DRCExecutionResult }
    struct Result {
        let snapshot: PhysicalDesignSnapshot
        let evidence: PhysicalDesignRepairMeasurementEvidence?
        var sourceAntennaEvidence: PhysicalDesignSourceAntennaMeasurementEvidence? = nil
    }
    let reference: PhysicalDesignRepairMeasurementReference
    let profile: PhysicalDesignRepairMeasurementProfile

    static func load(request: PhysicalDesignRequest, store: any PhysicalDesignArtifactStore) async throws -> Self? {
        guard let reference = request.repairMeasurementProfile else { return nil }
        let limits = reference.limits, binding = reference.artifact
        guard limits.maximumInputBytes > 0, limits.maximumProjectionRecords > 0, limits.maximumGeometryProbes > 0,
              limits.maximumBackendWork > 0, limits.timeoutSeconds.isFinite, limits.timeoutSeconds > 0,
              binding.reference.byteCount <= UInt64(limits.maximumInputBytes), binding.descriptor.format == .json,
              binding.descriptor.role == .input, binding.reference.digest.algorithm == .sha256,
              request.inputs.contains(binding.reference) else { throw PhysicalDesignTechnologyError.invalid("Invalid exact repair profile or limits.") }
        let bytes = try await store.read(binding)
        guard UInt64(bytes.count) == binding.reference.byteCount,
              try SHA256ContentDigester().digest(data: bytes, using: .sha256) == binding.reference.digest else {
            throw PhysicalDesignTechnologyError.invalid("Repair profile source bytes changed.")
        }
        let profile = try PhysicalDesignJSONCodec().decode(PhysicalDesignRepairMeasurementProfile.self, from: bytes)
        guard (profile.antennaLimitPolicy == .sourceProcessLaws ? profile.schemaVersion == 2 : profile.schemaVersion == 1),
              profile.processManifest == request.pdk.manifest,
              profile.processAssets == request.processAssets.mapValues(\.reference),
              (profile.antennaLimitPolicy == .sourceProcessLaws ? profile.rules.isEmpty && profile.hotspots.isEmpty && !profile.antennaNetIDs.isEmpty : !profile.rules.isEmpty),
              Set(profile.rules.map(\.id)).count == profile.rules.count,
              !profile.processLayerOrder.isEmpty, Set(profile.processLayerOrder).count == profile.processLayerOrder.count,
              Set(profile.antennaNetIDs).count == profile.antennaNetIDs.count,
              Set(profile.hotspots.map(\.hotspotID)).count == profile.hotspots.count else {
            throw PhysicalDesignTechnologyError.invalid("Repair requires one exact process/rule/target profile without duplicate identities.")
        }
        if profile.requireNumericalAntennaRatio && profile.antennaLimitPolicy != .sourceProcessLaws {
            throw PhysicalDesignTechnologyError.unsupported("NativeDRC exposes rule verdicts, not numerical ratios for clean antenna results.")
        }
        return Self(reference: reference, profile: profile)
    }

    func repair(_ input: PhysicalDesignSnapshot, stage: PhysicalDesignStage, configuration: PhysicalDesignConfiguration,
                geometry: PhysicalDesignProcessGeometry, sourceAntennaProjection: PhysicalDesignAntennaSourceProjection? = nil) async throws -> Result {
        if profile.antennaLimitPolicy == .sourceProcessLaws {
            guard stage == .antennaRepair, let sourceAntennaProjection else {
                throw PhysicalDesignTechnologyError.unsupported("Source-process repair requires antenna stage and exact source laws.")
            }
            let measurement = try NativePhysicalDesignSourceAntennaMeasurement(reference: reference, profile: profile,
                source: sourceAntennaProjection)
            return try measurement.repair(input, configuration: configuration, geometry: geometry) { snapshot, bypass in
                try makeCandidate(snapshot, stage: stage, configuration: configuration, geometry: geometry, sourceBypassLayers: bypass)
            }
        }
        try validateProfile(input, stage: stage, configuration: configuration, geometry: geometry)
        var targets = stage == .antennaRepair ? Set(profile.antennaNetIDs) : Set(input.nets.map(\.id))
        if stage == .antennaRepair, configuration.repairConstraints?.antennaStrategy == .protectionDevice {
            targets.formUnion(profile.protection?.otherPinNetIDs.values.map { $0 } ?? [])
        }
        let beforeProjection = try PhysicalDesignRepairProjection(snapshot: input, geometry: geometry, profile: profile,
            limits: reference.limits, requireGateFacts: stage == .antennaRepair)
        try beforeProjection.validateConnectivity(targetNetIDs: targets)
        var backendWork = reference.limits.maximumBackendWork
        let deadline = ContinuousClock.now.advanced(by: .seconds(reference.limits.timeoutSeconds))
        let before = try await evaluate(beforeProjection, remainingWork: &backendWork, deadline: deadline)
        try validateBeforeCoverage(before, snapshot: input, stage: stage, sourceIDs: beforeProjection.sourceIDByRecordID)
        guard before.contains(where: { $0.result.result.diagnostics.contains { $0.severity == .error } }) else {
            throw PhysicalDesignTechnologyError.invalid("The exact required rules identify no violation to repair.")
        }
        var output = try makeCandidate(input, stage: stage, configuration: configuration, geometry: geometry)
        guard output.routes != input.routes || output.vias != input.vias || output.fills != input.fills || output.cells != input.cells else {
            throw PhysicalDesignTechnologyError.invalid("Repair made no physical geometry change.")
        }
        let afterProjection = try PhysicalDesignRepairProjection(snapshot: output, geometry: geometry, profile: profile,
            limits: reference.limits, requireGateFacts: stage == .antennaRepair)
        try afterProjection.validateConnectivity(targetNetIDs: targets)
        let after = try await evaluate(afterProjection, remainingWork: &backendWork, deadline: deadline)
        guard after.allSatisfy({ $0.result.result.completed && $0.result.result.success && !$0.result.result.diagnostics.contains { $0.severity == .error } }) else {
            throw PhysicalDesignTechnologyError.invalid("The candidate retains required native rule violations.")
        }
        let rules = profile.rules.map(\.id).sorted()
        if stage == .antennaRepair {
            for id in profile.antennaNetIDs {
                output.antennaRepairs.append(.init(id: "measured-\(id)-\(output.antennaRepairs.count)", netID: id,
                    strategy: (configuration.repairConstraints ?? .default).antennaStrategy.rawValue,
                    previousRatio: nil, resultingRatio: nil, ratioStatus: .unavailableFromNativeRuleVerdict, satisfiedRuleIDs: rules))
                if let index = output.nets.firstIndex(where: { $0.id == id }) { output.nets[index].antennaRatio = nil }
            }
        } else {
            for index in output.hotspots.indices where profile.hotspots.contains(where: { $0.hotspotID == output.hotspots[index].id }) {
                output.hotspots[index].resolved = true; output.hotspots[index].resolution = "exact_native_rule_verdict"
            }
        }
        output.implementationState?.repairProofs.removeAll()
        output.implementationState?.routingEvidence = nil
        for index in output.clockTrees.indices { output.clockTrees[index].timingEstimate = nil }
        var state = output.implementationState ?? .init()
        state.repairProofs.append(.init(stage: stage.rawValue, strategy: "source_bound_native_rule_remeasurement",
            targetIDs: stage == .antennaRepair ? profile.antennaNetIDs : profile.hotspots.map(\.hotspotID),
            violationsBefore: before.reduce(0) { $0 + $1.result.result.diagnostics.filter { $0.severity == .error }.count },
            violationsAfter: 0, verified: true, details: ["exact_rule_source_binding", "complete_gate_net_coverage", "native_rule_verdict_and_actual_connectivity"]))
        output.implementationState = state
        let codec = PhysicalDesignJSONCodec(), hasher = SHA256ContentDigester()
        let checks = zip(before, after).map { PhysicalDesignRepairMeasurementEvidence.Check(ruleIDs: $0.0.layout.rules.map(\.id),
            beforeLayout: $0.0.layout, afterLayout: $0.1.layout, before: $0.0.result, after: $0.1.result) }
        return .init(snapshot: output, evidence: .init(profile: reference.artifact.reference,
            beforeSnapshotDigest: try hasher.digest(data: codec.encode(input), using: .sha256),
            afterSnapshotDigest: try hasher.digest(data: codec.encode(output), using: .sha256), targetNetIDs: targets.sorted(),
            targetGatePinIDs: afterProjection.targetGatePinIDs, checks: checks))
    }

    private func makeCandidate(_ input: PhysicalDesignSnapshot, stage: PhysicalDesignStage,
                               configuration: PhysicalDesignConfiguration, geometry: PhysicalDesignProcessGeometry,
                               sourceBypassLayers: Set<Int>? = nil) throws -> PhysicalDesignSnapshot {
        var targets = Set(profile.antennaNetIDs)
        if configuration.repairConstraints?.antennaStrategy == .protectionDevice {
            targets.formUnion(profile.protection?.otherPinNetIDs.values.map { $0 } ?? [])
        }
        var output = input
        if stage == .antennaRepair {
            switch (configuration.repairConstraints ?? .default).antennaStrategy {
            case .reroute:
                for id in profile.antennaNetIDs.sorted() {
                    output = try PhysicalDesignSourceRouter().route(output, configuration: configuration, mode: "antenna-reroute", onlyNetID: id, geometry: geometry).snapshot
                }
            case .jumper:
                let bypass = try sourceBypassLayers ?? Set(profile.rules.filter { $0.kind == .maximumAntennaRatio }.map { rule -> Int in
                    guard let number = geometry.sourceLayers.first(where: { $0.value.name == rule.layer })?.key else { throw PhysicalDesignTechnologyError.invalid("Unknown antenna layer.") }
                    return Int(number)
                })
                for id in profile.antennaNetIDs.sorted() {
                    output = try PhysicalDesignSourceRouter().route(output, configuration: configuration, mode: "antenna-jumper", onlyNetID: id,
                        geometry: geometry, bypassingLayers: bypass).snapshot
                }
            case .protectionDevice:
                output = try insertProtection(input, configuration: configuration, geometry: geometry)
                for id in targets.sorted() {
                    output = try PhysicalDesignSourceRouter().route(output, configuration: configuration, mode: "antenna-protection", onlyNetID: id, geometry: geometry).snapshot
                }
            }
        } else {
            for constraint in profile.hotspots {
                guard let hotspot = input.hotspots.first(where: { $0.id == constraint.hotspotID && !$0.resolved }) else {
                    throw PhysicalDesignTechnologyError.invalid("Hotspot constraint requires its exact unresolved target.")
                }
                switch constraint.predicate {
                case .metalSpacing(_, let ids):
                    guard !ids.isEmpty, Set(ids).isSubset(of: Set(input.nets.map(\.id))) else { throw PhysicalDesignTechnologyError.invalid("Unknown spacing repair net.") }
                    output.blockages.append(hotspot.geometry)
                    for id in ids.sorted() { output = try PhysicalDesignSourceRouter().route(output, configuration: configuration, mode: "hotspot-spacing", onlyNetID: id, geometry: geometry).snapshot }
                case .fillDensity(_, let ids):
                    guard !ids.isEmpty, Set(ids).isSubset(of: Set(output.fills.map(\.id))) else { throw PhysicalDesignTechnologyError.invalid("Unknown density repair fill.") }
                    output.fills.removeAll { ids.contains($0.id) }
                case .viaCutSpacing(_, let ids):
                    guard !ids.isEmpty, ids.allSatisfy({ id in output.vias.contains { $0.id == id && $0.isRedundant } }) else {
                        throw PhysicalDesignTechnologyError.unsupported("Cut spacing removal requires selected redundant contacts; primary connectivity is retained.")
                    }
                    output.vias.removeAll { ids.contains($0.id) }
                }
            }
        }
        return output
    }

    private func validateProfile(_ snapshot: PhysicalDesignSnapshot, stage: PhysicalDesignStage,
                                 configuration: PhysicalDesignConfiguration, geometry: PhysicalDesignProcessGeometry) throws {
        let order = Dictionary(uniqueKeysWithValues: profile.processLayerOrder.enumerated().map { ($0.element, $0.offset) })
        guard Set(profile.processLayerOrder).isSubset(of: Set(geometry.sourceLayers.values.filter { $0.type == .routing || $0.type == .cut }.map(\.name))) else {
            throw PhysicalDesignTechnologyError.invalid("Etch order requires actual source metal/cut layer names.")
        }
        for via in geometry.vias.values {
            guard let lower = geometry.sourceLayers[via.lowerLayer]?.name, let upper = geometry.sourceLayers[via.upperLayer]?.name,
                  let first = order[lower], let second = order[upper], first < second,
                  geometry.sourceLayers[via.cutLayer].map({ source in order[source.name].map { first < $0 && $0 < second } ?? true }) == true else {
                throw PhysicalDesignTechnologyError.invalid("Ordered etch layers contradict the exact fixed contact stack.")
            }
        }
        for rule in profile.rules {
            guard !rule.id.isEmpty, rule.value.isFinite, rule.value > 0,
                  geometry.sourceLayers.values.contains(where: { $0.name == rule.layer }) else { throw PhysicalDesignTechnologyError.invalid("Invalid source-bound rule.") }
            if rule.kind == .maximumAntennaRatio {
                guard rule.antennaModel != nil, let layers = rule.antennaLayers, !layers.isEmpty,
                      let stageRank = order[rule.layer], !Set(layers.map(\.layer)).isEmpty,
                      Set(layers.map(\.layer)).count == layers.count,
                      layers.allSatisfy({ order[$0.layer].map { $0 <= stageRank } == true }),
                      layers.map({ order[$0.layer]! }) == layers.map({ order[$0.layer]! }).sorted(),
                      rule.antennaModel != .partial || layers.count == 1 else {
                    throw PhysicalDesignTechnologyError.invalid("Antenna active layers require explicit compatible source etch order.")
                }
                let expected = Set(geometry.vias.values.compactMap { via -> NativeDRCAntennaCutConnection? in
                    guard let cut = geometry.sourceLayers[via.cutLayer]?.name,
                          let lower = geometry.sourceLayers[via.lowerLayer]?.name,
                          let upper = geometry.sourceLayers[via.upperLayer]?.name,
                          order[lower].map({ $0 <= stageRank }) == true,
                          (order[cut] ?? order[upper]).map({ $0 <= stageRank }) == true else { return nil }
                    return .init(layer: cut, lowerLayer: lower, upperLayer: upper)
                })
                let supplied = rule.antennaCutConnections ?? []
                guard Set(supplied) == expected, Set(supplied).count == supplied.count else {
                    throw PhysicalDesignTechnologyError.invalid("Antenna cut relations must completely match the active named source contact stacks.")
                }
                // Scalar limits only map exactly to the existing simple partial law.
                let simpleScalarLaw = rule.antennaModel == .partial && layers.count == 1
                    && layers[0].ratioGate == rule.value && layers[0].diffusionRatioConstant == nil
                    && layers[0].diffusionRatioPerArea == nil
                for net in snapshot.nets where profile.antennaNetIDs.contains(net.id) {
                    guard profile.antennaLimitPolicy == .nativeRuleVerdict || (simpleScalarLaw && (net.maximumAntennaRatio ?? configuration.maximumAntennaRatio) == rule.value) else {
                        throw PhysicalDesignTechnologyError.invalid("Legacy scalar limits require the exact simple partial native law and equal configured/net limit.")
                    }
                }
            }
        }
        if stage == .antennaRepair {
            guard profile.hotspots.isEmpty, profile.rules.allSatisfy({ $0.kind == .maximumAntennaRatio }) else {
                throw PhysicalDesignTechnologyError.invalid("Antenna profiles contain only required antenna rules and net targets.")
            }
            guard !profile.antennaNetIDs.isEmpty, profile.rules.contains(where: { $0.kind == .maximumAntennaRatio }) else { throw PhysicalDesignTechnologyError.invalid("Antenna repair requires explicit nets and actual rules.") }
        } else {
            guard profile.antennaNetIDs.isEmpty, Set(profile.hotspots.map { $0.predicate.ruleID }) == Set(profile.rules.map(\.id)) else {
                throw PhysicalDesignTechnologyError.invalid("Hotspot profiles require exact typed rule coverage without unrelated rules.")
            }
            guard !profile.hotspots.isEmpty, Set(snapshot.hotspots.filter { !$0.resolved }.map(\.id)) == Set(profile.hotspots.map(\.hotspotID)) else {
                throw PhysicalDesignTechnologyError.invalid("Every unresolved hotspot requires exactly one typed measurement constraint.")
            }
            for constraint in profile.hotspots {
                guard let rule = profile.rules.first(where: { $0.id == constraint.predicate.ruleID }) else { throw PhysicalDesignTechnologyError.invalid("Missing hotspot rule.") }
                switch constraint.predicate {
                case .metalSpacing:
                    guard rule.kind == .minimumSpacing, geometry.sourceLayers.values.contains(where: { $0.name == rule.layer && $0.type == .routing }) else { throw PhysicalDesignTechnologyError.invalid("Metal spacing requires a routing-layer spacing rule.") }
                case .fillDensity:
                    guard rule.kind == .maximumDensity, rule.windowWidth != nil, rule.windowHeight != nil,
                          rule.windowOriginX != nil, rule.windowOriginY != nil,
                          let hotspot = snapshot.hotspots.first(where: { $0.id == constraint.hotspotID }),
                          Double(hotspot.geometry.x) / Double(snapshot.unitsPerMicron) == rule.windowOriginX,
                          Double(hotspot.geometry.y) / Double(snapshot.unitsPerMicron) == rule.windowOriginY,
                          Double(hotspot.geometry.width) / Double(snapshot.unitsPerMicron) == rule.windowWidth,
                          Double(hotspot.geometry.height) / Double(snapshot.unitsPerMicron) == rule.windowHeight else {
                        throw PhysicalDesignTechnologyError.invalid("Density requires its exact declared hotspot window.")
                    }
                case .viaCutSpacing:
                    guard rule.kind == .minimumSpacing, geometry.sourceLayers.values.contains(where: { $0.name == rule.layer && $0.type == .cut }) else { throw PhysicalDesignTechnologyError.invalid("Cut spacing requires an exact cut-layer spacing rule.") }
                }
            }
        }
    }

    private func evaluate(_ projection: PhysicalDesignRepairProjection, remainingWork: inout Int,
                          deadline: ContinuousClock.Instant) async throws -> [Evaluation] {
        let root = FileManager.default.temporaryDirectory.appending(path: "physical-rule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var results: [Evaluation] = []
            for (index, rule) in profile.rules.enumerated() {
                try Task.checkCancellation()
                let layout = try projection.layout(rule: rule), n = layout.rectangles.count
                let size = max(1, n)
                let square = size.multipliedReportingOverflow(by: size), cube = square.partialValue.multipliedReportingOverflow(by: size)
                let windows = try densityWindowAdmission(layout, rule: rule)
                let work = cube.partialValue.multipliedReportingOverflow(by: windows)
                guard !square.overflow, !cube.overflow, !work.overflow, work.partialValue <= remainingWork,
                      ContinuousClock.now < deadline else {
                    throw PhysicalDesignTechnologyError.invalid("Native rule work admission ceiling exceeded.")
                }
                remainingWork -= work.partialValue
                let bytes = try PhysicalDesignJSONCodec().encode(layout)
                guard bytes.count <= reference.limits.maximumInputBytes else { throw PhysicalDesignTechnologyError.invalid("Native projection input-byte ceiling exceeded.") }
                let path = root.appending(path: "rule-\(index).json"); try bytes.write(to: path, options: .atomic)
                let result = try await NativeDRCBackend().run(.init(layoutURL: path, topCell: layout.topCell, layoutFormat: .nativeJSON,
                    backendSelection: .init(backendID: "native"), options: .init(timeoutSeconds: reference.limits.timeoutSeconds,
                    requireAntennaRules: rule.kind == .maximumAntennaRatio), executionInputArtifacts: [reference.artifact.reference]),
                    cancellationCheck: { Task.isCancelled || ContinuousClock.now >= deadline })
                guard result.result.completed && result.result.success else { throw PhysicalDesignTechnologyError.invalid("Native rule evaluation did not complete.") }
                results.append(.init(layout: layout, result: result))
            }
            try FileManager.default.removeItem(at: root)
            return results
        } catch {
            do { try FileManager.default.removeItem(at: root) }
            catch { throw PhysicalDesignTechnologyError.invalid("Native repair temporary resource cleanup failed: \(error)") }
            throw error
        }
    }

    private func densityWindowAdmission(_ layout: NativeDRCLayout, rule: NativeDRCRule) throws -> Int {
        guard rule.kind == .maximumDensity else { return 1 }
        guard let width = rule.windowWidth, let height = rule.windowHeight,
              let originX = rule.windowOriginX, let originY = rule.windowOriginY,
              width.isFinite, height.isFinite, width > 0, height > 0, originX.isFinite, originY.isFinite else {
            throw PhysicalDesignTechnologyError.invalid("Invalid explicit density window.")
        }
        let stepX = rule.stepX ?? width, stepY = rule.stepY ?? height
        guard stepX.isFinite, stepY.isFinite, stepX > 0, stepY > 0 else { throw PhysicalDesignTechnologyError.invalid("Invalid density lattice step.") }
        let relevant = layout.rectangles.filter { $0.layer == rule.layer }
        let bounds = relevant.isEmpty ? layout.rectangles : relevant
        let maxX = bounds.map(\.xMax).max() ?? (originX + width), maxY = bounds.map(\.yMax).max() ?? (originY + height)
        let columns = max(1, floor((maxX - width + 1e-9 - originX) / stepX) + 1)
        let rows = max(1, floor((maxY - height + 1e-9 - originY) / stepY) + 1)
        let count = columns * rows
        guard count.isFinite, count <= Double(reference.limits.maximumBackendWork) else { throw PhysicalDesignTechnologyError.invalid("Density window work ceiling exceeded.") }
        return Int(count)
    }

    private func validateBeforeCoverage(_ before: [Evaluation], snapshot: PhysicalDesignSnapshot, stage: PhysicalDesignStage,
                                        sourceIDs: [String: String]) throws {
        let diagnostics = before.flatMap { $0.result.result.diagnostics }.filter { $0.severity == .error }
        if stage == .antennaRepair {
            for net in profile.antennaNetIDs {
                guard diagnostics.contains(where: { $0.relatedNetIDs.contains(net) }) else {
                    throw PhysicalDesignTechnologyError.invalid("Requested antenna net has no actual before violation.")
                }
            }
        } else {
            for constraint in profile.hotspots {
                guard let hotspot = snapshot.hotspots.first(where: { $0.id == constraint.hotspotID }) else { throw PhysicalDesignTechnologyError.invalid("Unknown hotspot target.") }
                let scale = Double(snapshot.unitsPerMicron), rect = hotspot.geometry
                let covered = diagnostics.contains { diagnostic in
                    guard diagnostic.ruleID == constraint.predicate.ruleID, let region = diagnostic.region,
                          region.x < Double(rect.maxX) / scale, region.x + region.width > Double(rect.x) / scale,
                          region.y < Double(rect.maxY) / scale, region.y + region.height > Double(rect.y) / scale else { return false }
                    switch constraint.predicate {
                    case .metalSpacing(_, let ids):
                        return diagnostic.relatedShapeIDs.contains { id in
                            before.flatMap { $0.layout.rectangles }.contains { $0.id == id && $0.netID.map { ids.contains($0) } == true }
                        }
                    case .fillDensity(_, let ids): return diagnostic.relatedShapeIDs.contains { shape in ids.contains { sourceIDs[shape] == "fill:" + $0 } }
                    case .viaCutSpacing(_, let ids): return diagnostic.relatedShapeIDs.contains { shape in ids.contains { sourceIDs[shape] == "via:" + $0 } }
                    }
                }
                guard covered else { throw PhysicalDesignTechnologyError.invalid("Hotspot has no before violation on its exact rule/window/selected geometry.") }
            }
        }
    }

    private func insertProtection(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
                                  geometry: PhysicalDesignProcessGeometry) throws -> PhysicalDesignSnapshot {
        guard let source = profile.protection else { throw PhysicalDesignTechnologyError.unsupported("Protection requires an exact selected device/diffusion interface.") }
        let master = try geometry.requireMaster(source.master)
        guard let diffusion = master.pins[source.diffusionPin]?.definition.antennaDiffArea, diffusion.isFinite, diffusion > 0,
              Set(master.pins.keys) == Set(source.otherPinNetIDs.keys).union([source.diffusionPin]),
              (profile.antennaLimitPolicy == .sourceProcessLaws || profile.rules.contains(where: { $0.antennaLayers?.contains { $0.diffusionCorrection == .finite } == true })) else {
            throw PhysicalDesignTechnologyError.unsupported("Protection requires complete source diffusion facts and the existing diffusion correction law.")
        }
        var output = input
        let locks = Dictionary(uniqueKeysWithValues: output.cells.map { ($0.id, $0.locked) })
        for index in output.cells.indices { output.cells[index].locked = true }
        for net in profile.antennaNetIDs.sorted() {
            let id = "antenna-protection-" + net
            guard !output.cells.contains(where: { $0.id == id }) else { throw PhysicalDesignTechnologyError.invalid("Protection instance identity collision.") }
            let cell = PhysicalDesignSnapshot.Cell(id: id, master: source.master, width: master.width, height: master.height)
            output.cells.append(cell)
            for name in master.pins.keys.sorted() {
                let netID = name == source.diffusionPin ? net : source.otherPinNetIDs[name]!
                guard let netIndex = output.nets.firstIndex(where: { $0.id == netID }) else { throw PhysicalDesignTechnologyError.invalid("Protection pin references an unknown net.") }
                let pinID = id + "/" + name
                output.pins.append(try geometry.referencePin(.init(id: pinID, cellID: id, name: name, netID: netID), for: cell))
                output.nets[netIndex].pinIDs.append(pinID)
            }
        }
        output = try NativePhysicalDesignPlacementAllocator().allocate(output, configuration: configuration, processGeometry: geometry).snapshot
        for index in output.cells.indices { output.cells[index].locked = locks[output.cells[index].id] ?? false }
        return output
    }
}
