import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import STAEngine
import TimingCore

struct NativePhysicalDesignTimingPlacer {
    func optimize(_ baseline: PhysicalDesignPlacementAllocation, request: PhysicalDesignRequest,
                  geometry: PhysicalDesignProcessGeometry, characterization: NativePhysicalDesignPlacementCharacterization)
        async throws -> (PhysicalDesignPlacementAllocation, PhysicalDesignPlacementTimingEvidence) {
        let budget = characterization.budget
        let indices = baseline.snapshot.cells.indices.filter { !baseline.snapshot.cells[$0].locked }
            .sorted { baseline.snapshot.cells[$0].id < baseline.snapshot.cells[$1].id }
        let pairs = try multiplied(indices.count, max(0, indices.count - 1)) / 2
        let structural = try added(baseline.structuralCeiling, try added(pairs, 1))
        let ceiling = min(request.configuration.maximumPlacementCandidateChecks ?? structural, structural)
        var checks = baseline.candidateChecks
        var candidates: [PhysicalDesignPlacementTimingEvidence.Candidate] = []
        var selectedIndex = 0
        var selected = baseline.snapshot
        let sequential = characterization.profile.isSourceBoundSequential
        func evaluate(_ snapshot: PhysicalDesignSnapshot, swapped: [String]) async throws -> PhysicalDesignPlacementTimingEvidence.Candidate {
            try budget.check()
            guard checks < ceiling else { throw PhysicalDesignPlacementError.candidateBudget }
            checks += 1
            let design = try characterization.projected(snapshot, geometry: geometry)
            let rc = try characterization.rcProjection?.project(snapshot, graph: design, budget: budget)
            defer { withExtendedLifetime(rc) {} }
            let bytes = try PhysicalDesignJSONCodec().encode(design)
            try budget.chargeInput(UInt64(bytes.count))
            try budget.chargeWork(UInt64(bytes.count))
            let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: bytes, using: .sha256),
                byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .json))
            let binding = try TimingArtifactBinding(reference: reference, availability: .service(artifactID: reference.id,
                resource: .init(serviceID: .init(rawValue: "physical-placement-memory"), namespaceID: .init(rawValue: request.runID),
                                resourceID: .init(rawValue: reference.digest.hexadecimalValue), generation: 1)))
            var sources = characterization.inputData; sources[reference.id] = bytes
            if let rc { sources[rc.reference.id] = rc.spef }
            let rcBinding = try rc.map { value in
                try TimingArtifactBinding(reference: value.reference, availability: .service(artifactID: value.reference.id,
                    resource: .init(serviceID: .init(rawValue: "physical-placement-memory"), namespaceID: .init(rawValue: request.runID),
                                    resourceID: .init(rawValue: value.reference.digest.hexadecimalValue), generation: 1)))
            }
            let pathBound = max(1, try multiplied(budget.reference.maximumPathStates, max(1, design.ports.count)))
            func timing(_ binding: PhysicalDesignArtifactBinding) throws -> TimingArtifactBinding {
                try .init(reference: binding.reference, availability: binding.availability)
            }
            let sta = try STARequest(runID: request.runID + "-placement-\(checks)", design: binding, topDesignName: design.topDesignName,
                libraries: [.init(artifact: timing(characterization.profile.library), cornerIDs: [characterization.profile.cornerID])],
                constraints: timing(request.constraints), requestedModeIDs: request.requestedModeIDs,
                requestedCornerIDs: [characterization.profile.cornerID], pdkManifest: timing(request.requireBinding(for: request.pdk.manifest)),
                processID: request.pdk.processID, pdkVersion: request.pdk.version, parasitics: rcBinding,
                analysisKinds: sequential ? [.setup, .hold, .recovery, .removal, .pulseWidth] : [.setup], maxPaths: pathBound,
                characterizationPolicy: .requireObservedConditions,
                characterizationBindings: [.init(cornerID: characterization.profile.cornerID, conditionName: characterization.profile.conditionName)],
                distributedRC: characterization.profile.distributedRC, requireStrictSourceEvidence: sequential,
                operatingSupplyAssumptions: characterization.profile.operatingSupplyAssumptions ?? [])
            let limits = try STAExecutionLimits(maximumInputBytes: budget.reference.maximumInputBytes,
                maximumScenarios: max(1, request.requestedModeIDs.count),
                maximumDesignElements: max(1, try added(try added(design.ports.count, design.instances.count), try added(design.nets.count, snapshot.pins.count))),
                maximumPaths: pathBound, maximumPathStates: budget.reference.maximumPathStates,
                maximumPathWorkUnits: budget.reference.maximumPathWorkUnitsPerAnalysis)
            let reader = InMemoryTimingArtifactReader(artifacts: sources)
            let engine = NativeSTAEngine(reader: reader, libraryParser: characterization.parser)
            let resources = try STAExecutionResources(reader: reader,
                sourceLimits: .init(maximumNestingDepth: 64), sourceResources: budget, limits: limits)
            // Cached non-Liberty transforms reserve one logical byte unit per actual input byte.
            for count in [UInt64(bytes.count), request.constraints.reference.byteCount, request.pdk.manifest.byteCount, UInt64(rc?.spef.count ?? 0)] {
                try budget.chargeWork(count)
            }
            let prepared: PreparedSTAExecution
            do { prepared = try await engine.prepare(sta, resources: resources) }
            catch .cancelled { throw CancellationError() }
            catch .liberty(.resource(let cause)) where cause is PhysicalDesignPlacementTimingError { throw cause }
            catch .underlying(let cause) where cause is PhysicalDesignPlacementTimingError { throw cause }
            catch { throw PhysicalDesignPlacementTimingError.preparation(error) }
            try budget.chargeWork(budget.reference.maximumPathWorkUnitsPerAnalysis)
            let result: STAExecutionResult
            do { result = try await engine.execute(prepared) }
            catch .cancelled { throw CancellationError() }
            catch .underlying(let cause) where cause is PhysicalDesignPlacementTimingError { throw cause }
            catch { throw PhysicalDesignPlacementTimingError.execution(error) }
            try budget.check()
            guard result.status == .completed, result.payload.unconstrainedEndpoints.isEmpty,
                  result.payload.analyzedCorners == [characterization.profile.cornerID],
                  Set(result.payload.analyzedModes) == Set(request.requestedModeIDs),
                  result.payload.characterization.contains(where: { $0.selected && $0.cornerID == characterization.profile.cornerID && $0.conditionName == characterization.profile.conditionName }) else {
                throw PhysicalDesignPlacementTimingError.unavailableTiming("The exact characterized STA candidate lacks complete constrained evidence: \(result.diagnostics)")
            }
            let rejection: String?
            if sequential {
                try budget.chargeWork(budget.reference.maximumPathWorkUnitsPerAnalysis)
                do { try await engine.validateSourceEvidence(result, against: prepared) }
                catch .cancelled { throw CancellationError() }
                catch .underlying(let cause) where cause is PhysicalDesignPlacementTimingError { throw cause }
                catch { throw PhysicalDesignPlacementTimingError.execution(error) }
                rejection = try PhysicalDesignPlacementTimingEvidence.nonSetupRejection(result,
                    profile: characterization.profile, budget: budget)
                _ = try PhysicalDesignPlacementTimingEvidence.setupMetric(result)
            } else {
                _ = try setupSlack(result)
                do { try characterization.checkCharacterizedPaths(result) }
                catch let error as TimingCharacterizationError { throw PhysicalDesignPlacementTimingError.characterization(error) }
                rejection = nil
            }
            let candidate = PhysicalDesignPlacementTimingEvidence.Candidate(swappedCellIDs: swapped,
                snapshotDigest: try PhysicalDesignPlacementTimingEvidence.geometryDigest(snapshot),
                timingDesign: design, timingDesignReference: reference, accepted: rejection == nil, rejection: rejection, result: result,
                rcInput: rc.map { .init(bytes: $0.spef, reference: $0.reference) })
            return candidate
        }
        func retain(_ candidate: PhysicalDesignPlacementTimingEvidence.Candidate) throws {
            struct CandidateEnvelope: Encodable { let candidates: [PhysicalDesignPlacementTimingEvidence.Candidate] }
            // Match its two-level pretty-printed nesting; redundant wrapper punctuation is a conservative bound.
            let byteCount = UInt64(sequential
                ? try PhysicalDesignJSONCodec().encode(CandidateEnvelope(candidates: [candidate])).count
                : try PhysicalDesignJSONCodec().encode(candidate).count)
            try budget.chargeEvidence(byteCount)
            try budget.chargeWork(byteCount)
            if sequential { try budget.retainEvidenceStorage(byteCount) }
            candidates.append(candidate)
        }
        let initial = try await evaluate(selected, swapped: [])
        guard initial.accepted else {
            throw PhysicalDesignPlacementTimingError.unavailableTiming("Baseline fails a required non-setup check: \(initial.rejection ?? "unknown")")
        }
        try retain(initial)
        var slack: Double? = sequential ? try PhysicalDesignPlacementTimingEvidence.setupMetric(initial.result) : try setupSlack(initial.result)
        if sequential && slack == nil && characterization.profile.minimumSetupSlackSeconds != nil {
            throw PhysicalDesignPlacementTimingError.unavailableTiming("An explicit setup minimum requires a finite measured metric")
        }
        for first in indices.indices where slack != nil {
            for second in indices.indices where second > first {
                try budget.check()
                let a = indices[first], b = indices[second]
                let previousA = selected.cells[a], previousB = selected.cells[b]
                guard previousA.width == previousB.width, previousA.height == previousB.height else { continue }
                var candidate = selected
                candidate.cells[a].x = previousB.x; candidate.cells[a].y = previousB.y; candidate.cells[a].orientation = previousB.orientation
                candidate.cells[b].x = previousA.x; candidate.cells[b].y = previousA.y; candidate.cells[b].orientation = previousA.orientation
                var legal = true
                for index in [a, b] {
                    let cell = candidate.cells[index]
                    let dimensions = try geometry.dimensions(master: cell.master, orientation: cell.orientation)
                    if dimensions.width != cell.width || dimensions.height != cell.height
                        || !candidate.rows.contains(where: { $0.originY == cell.y && geometry.canPlace(cell, on: $0) }) { legal = false }
                }
                if !legal { continue }
                for index in candidate.pins.indices where candidate.pins[index].cellID == previousA.id || candidate.pins[index].cellID == previousB.id {
                    let cell = candidate.pins[index].cellID == previousA.id ? candidate.cells[a] : candidate.cells[b]
                    candidate.pins[index] = try geometry.referencePin(candidate.pins[index], for: cell)
                }
                try geometry.validate(candidate)
                let evaluated = try await evaluate(candidate, swapped: [previousA.id, previousB.id])
                let measured: Double? = sequential ? try PhysicalDesignPlacementTimingEvidence.setupMetric(evaluated.result) : try setupSlack(evaluated.result)
                guard let current = slack, let measured else {
                    throw PhysicalDesignPlacementTimingError.unavailableTiming("A pose candidate changed the setup objective applicability")
                }
                let accepted = evaluated.accepted && measured > current
                let decision = PhysicalDesignPlacementTimingEvidence.Candidate(swappedCellIDs: evaluated.swappedCellIDs,
                    snapshotDigest: evaluated.snapshotDigest, timingDesign: evaluated.timingDesign,
                    timingDesignReference: evaluated.timingDesignReference, accepted: accepted,
                    rejection: accepted ? nil : (evaluated.rejection ?? "Setup slack did not strictly improve"), result: evaluated.result,
                    rcInput: evaluated.rcInput)
                try retain(decision)
                if accepted { selected = candidate; slack = measured; selectedIndex = candidates.count - 1 }
            }
        }
        let minimum: Double? = sequential ? max(0, characterization.profile.minimumSetupSlackSeconds ?? 0)
            : characterization.profile.minimumSetupSlackSeconds
        if let minimum, let slack, slack < minimum {
            throw PhysicalDesignPlacementTimingError.unavailableTiming("Selected pre-route setup slack fails the required minimum")
        }
        try budget.check()
        let allocation = PhysicalDesignPlacementAllocation(snapshot: selected, candidateChecks: checks, candidateCeiling: ceiling,
            structuralCeiling: structural, blockageConflictCount: baseline.blockageConflictCount)
        func makeEvidence(_ retained: [PhysicalDesignPlacementTimingEvidence.Candidate], work: UInt64) -> PhysicalDesignPlacementTimingEvidence {
            .init(scope: sequential ? PhysicalDesignPlacementTimingEvidence.sequentialScope : "characterizedPreRouteCostOnly; limitedProcessCoverage; noPhysicalSignoff",
                schemaVersion: sequential ? 2 : nil, profileContent: sequential ? characterization.profile : nil,
                profileBytes: sequential ? characterization.inputData[budget.reference.artifact.reference.id] : nil,
                originalDesignReference: sequential ? request.design.artifact : nil, sourceBindings: characterization.sourceBindings,
                selectionDisposition: sequential ? (slack == nil ? .baselinePreservedNoApplicableSetup : .setupOptimization) : nil,
                model: characterization.profile.model, profile: budget.reference,
                candidates: retained, selectedCandidateIndex: selectedIndex, candidateChecks: checks, candidateCeiling: ceiling,
                structuralCeiling: structural, chargedWorkUnits: work)
        }
        if sequential {
            let header = try PhysicalDesignJSONCodec().encode(makeEvidence([], work: UInt64.max)).count
            let headerBound = try added(header, max(0, candidates.count - 1))
            try budget.chargeEvidence(UInt64(headerBound))
            try budget.chargeWork(UInt64(headerBound))
            try budget.retainEvidenceStorage(UInt64(headerBound))
        }
        let evidence = makeEvidence(candidates, work: budget.chargedWorkUnits)
        return (allocation, evidence)
    }
    private func setupSlack(_ result: STAExecutionResult) throws -> Double {
        guard let slack = result.payload.worstSetupSlack, slack.isFinite else {
            throw PhysicalDesignPlacementTimingError.unavailableTiming("Finite setup slack is unavailable")
        }
        return slack
    }
    private func added(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw PhysicalDesignPlacementError.arithmeticOverflow }
        return result.partialValue
    }
    private func multiplied(_ a: Int, _ b: Int) throws -> Int {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw PhysicalDesignPlacementError.arithmeticOverflow }
        return result.partialValue
    }
}
