import Foundation
import CircuiteFoundation
import Testing
import PEXCore
import TimingCore
import STAEngine
@testable import PhysicalDesignCore

@Suite("Source-bound pre-route RC projection", .serialized, .timeLimit(.minutes(2)))
struct PlacementRCProjectionTests {
    /// Called with the measured single-baseline filesystem FF result; it performs no additional solve.
    func assertSetupApplicabilityForgeryRefusal(_ snapshot: PhysicalDesignSnapshot) throws {
        let codec = PhysicalDesignJSONCodec()
        let original = try #require(snapshot.implementationState?.placementProof?.timingEvidence)
        try #require(original.schemaVersion == 2 && original.candidates.count == 1 && original.selectedCandidateIndex == 0)
        try #require(original.profileContent?.minimumSetupSlackSeconds == nil)
        try #require(original.selectionDisposition == .setupOptimization)
        try #require(original.candidates[0].result.payload.setupApplicability == .measured)
        try original.requireSelectedGeometry(snapshot)
        var root = try #require(JSONSerialization.jsonObject(with: codec.encode(snapshot)) as? [String: Any])
        var state = try #require(root["implementationState"] as? [String: Any])
        var proof = try #require(state["placementProof"] as? [String: Any])
        var evidence = try #require(proof["timingEvidence"] as? [String: Any])
        var candidates = try #require(evidence["candidates"] as? [[String: Any]])
        var result = try #require(candidates[0]["result"] as? [String: Any])
        var payload = try #require(result["payload"] as? [String: Any])
        payload["setupApplicability"] = "sourceNotApplicable"
        payload["worstSetupSlack"] = NSNull()
        result["payload"] = payload; candidates[0]["result"] = result
        evidence["candidates"] = candidates
        evidence["selectionDisposition"] = "baselinePreservedNoApplicableSetup"
        proof["timingEvidence"] = evidence; state["placementProof"] = proof; root["implementationState"] = state
        let forgedBytes = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: (any Error).self) {
            let changed = try codec.decode(PhysicalDesignSnapshot.self, from: forgedBytes)
            let changedEvidence = try #require(changed.implementationState?.placementProof?.timingEvidence)
            try changedEvidence.requireSelectedGeometry(changed)
        }
    }

    @Test("Setup metric projection distinguishes source nonapplicability from unknown or invented slack")
    func setupMetricApplicability() throws {
        let timestamp = try ExecutionTimestamp(secondsSinceUnixEpoch: 1)
        let provenance = try ExecutionProvenance(producer: .init(kind: .engine,
            identifier: "setup-applicability-projection-test", version: "1"),
            startedAt: timestamp, completedAt: timestamp)
        func result(_ applicability: STASetupApplicability?, _ slack: Double?) throws -> STAExecutionResult {
            try .init(runID: "setup-applicability-projection", status: .completed,
                payload: .init(worstSetupSlack: slack, worstHoldSlack: nil, analyzedCorners: [],
                    setupApplicability: applicability), provenance: provenance)
        }
        #expect(try PhysicalDesignPlacementTimingEvidence.setupMetric(result(.measured, 2e-9)) == 2e-9)
        #expect(try PhysicalDesignPlacementTimingEvidence.setupMetric(result(.sourceNotApplicable, nil)) == nil)
        for (applicability, slack) in [(STASetupApplicability.unknown, Double?.none), (.measured, nil), (.sourceNotApplicable, 0)] {
            #expect(throws: PhysicalDesignPlacementTimingError.self) {
                try PhysicalDesignPlacementTimingEvidence.setupMetric(result(applicability, slack))
            }
        }
        #expect(throws: PhysicalDesignPlacementTimingError.self) {
            try PhysicalDesignPlacementTimingEvidence.setupMetric(result(nil, 2e-9))
        }
    }

    /// Called with actual API/CLI reloads by SequentialPlacementTests; it performs no additional solve.
    func assertNonSelectedGraphRefusal(_ snapshot: PhysicalDesignSnapshot) throws {
        let codec = PhysicalDesignJSONCodec()
        let original = try #require(snapshot.implementationState?.placementProof?.timingEvidence)
        try #require(original.schemaVersion == 2)
        try original.requireSelectedGeometry(snapshot)
        let encoded = try codec.encode(snapshot)
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var state = try #require(root["implementationState"] as? [String: Any])
        var proof = try #require(state["placementProof"] as? [String: Any])
        var evidence = try #require(proof["timingEvidence"] as? [String: Any])
        var candidates = try #require(evidence["candidates"] as? [[String: Any]])
        let selected = try #require(evidence["selectedCandidateIndex"] as? Int)
        let target: Int
        if let nonselected = candidates.indices.first(where: { $0 != selected }) {
            target = nonselected
        } else {
            var duplicate = candidates[selected]
            duplicate["accepted"] = false
            duplicate["rejection"] = "Duplicate baseline does not improve setup slack"
            candidates.append(duplicate)
            target = candidates.count - 1
        }
        evidence["candidates"] = candidates; proof["timingEvidence"] = evidence
        state["placementProof"] = proof; root["implementationState"] = state
        let intact = try codec.decode(PhysicalDesignSnapshot.self, from: JSONSerialization.data(withJSONObject: root))
        let intactEvidence = try #require(intact.implementationState?.placementProof?.timingEvidence)
        try intactEvidence.requireSelectedGeometry(intact)
        let targetBefore = intactEvidence.candidates[target]

        var graph = try #require(candidates[target]["timingDesign"] as? [String: Any])
        graph["topDesignName"] = "changed-nonselected-top"
        candidates[target]["timingDesign"] = graph
        evidence["candidates"] = candidates; proof["timingEvidence"] = evidence
        state["placementProof"] = proof; root["implementationState"] = state
        let changed = try codec.decode(PhysicalDesignSnapshot.self, from: JSONSerialization.data(withJSONObject: root))
        let changedEvidence = try #require(changed.implementationState?.placementProof?.timingEvidence)
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try changedEvidence.requireSelectedGeometry(changed) }
        #expect(changed.validationDiagnostics().contains("placement timing evidence does not bind the selected geometry"))
        #expect(changedEvidence.candidates[selected] == original.candidates[selected])
        #expect(changedEvidence.candidates[target].timingDesignReference == targetBefore.timingDesignReference)
        #expect(changedEvidence.candidates[target].result == targetBefore.result)
        #expect(changedEvidence.candidates[target].rcInput == targetBefore.rcInput)
    }

    @Test("legacy profile bytes do not acquire sequential policy and schema two is explicit")
    func versionedProfile() async throws {
        let (request, store, _) = try await CharacterizedPlacementTests().fixture()
        let reference = try #require(request.placementTimingProfile)
        let original = try await store.read(reference.artifact)
        let legacy = try PhysicalDesignJSONCodec().decode(PhysicalDesignPlacementTimingProfile.self, from: original)
        let encoded = try PhysicalDesignJSONCodec().encode(legacy)
        #expect(encoded == original)
        #expect(legacy.schemaVersion == 1 && legacy.clockPolicy == nil && legacy.checkPolicy == nil)
        let master = try #require(request.initialSnapshot?.cells.first?.master)
        let supplied = try STAOperatingSupplyAssumption(instance: "U1", cell: master, cornerID: legacy.cornerID,
            library: legacy.library.reference, pin: "VPWR", sourcePGType: "primary_power", value: .one)
        let current = try sequential(legacy, supplies: [supplied])
        let loaded = try PhysicalDesignJSONCodec().decode(PhysicalDesignPlacementTimingProfile.self,
            from: PhysicalDesignJSONCodec().encode(current))
        #expect(loaded == current && loaded.isSourceBoundSequential)
        #expect(loaded.clockPolicy == .sourcePropagatedPrimary && loaded.checkPolicy == .completeSourceApplicable)
        #expect(loaded.manifest == legacy.manifest && loaded.library == legacy.library)
        #expect(loaded.operatingSupplyAssumptions == [supplied] && legacy.operatingSupplyAssumptions == nil)
        #expect(loaded.distributedRC != nil && legacy.distributedRC == nil)
    }

    @Test("selected actual LEF coefficients produce calculated pi RC and exact canonical SPEF terminals")
    func sourceRC() async throws {
        let fixture = try await fixture()
        let result = try fixture.projection.project(fixture.snapshot, graph: fixture.graph, budget: fixture.budget)
        #expect(result.network.nets.count == 4 && result.network.elements.count == 12)
        #expect(result.network.elements.allSatisfy { $0.source == .calculated })
        let input = try #require(fixture.snapshot.pins.first { $0.id == "a" })
        let sink = try #require(fixture.snapshot.pins.first { $0.id == "U1/A" })
        let length = (abs(Double(input.x) - Double(sink.x)) + abs(Double(input.y) - Double(sink.y))) / 1000
        let expectedR = 12.8 * (length / 0.17)
        let expectedC = (length * 0.17 * 36.9866e-6 + 2 * (length + 0.17) * 40.697e-6) * 1e-12
        let net = try #require(result.network.nets.first { $0.name.value == "a" })
        #expect(net.totalResistanceOhm == expectedR && net.totalGroundCapF == expectedC)
        let parsed = try SPEFParser().parse(result.spef)
        let parsedNet = try #require(parsed.network(named: "a"))
        #expect(Set(parsedNet.connections.map(\.name)) == ["a", "U1:A"])
        #expect(abs(parsedNet.resistanceInventory - expectedR) <= expectedR * 1e-10)
        #expect(result.reference.byteCount == UInt64(result.spef.count))
        #expect(result.snapshotDigest == (try PhysicalDesignPlacementTimingEvidence.geometryDigest(fixture.snapshot)))
    }

    @Test("coincident source endpoints retain both identities and explicit zero resistance without invented capacitance")
    func idealShortIdentity() async throws {
        let fixture = try await fixture()
        var snapshot = fixture.snapshot
        let driver = try #require(snapshot.pins.firstIndex { $0.id == "a" })
        let sink = try #require(snapshot.pins.first { $0.id == "U1/A" })
        snapshot.pins[driver].x = sink.x; snapshot.pins[driver].y = sink.y
        let port = try #require(snapshot.pins[driver].topPort)
        snapshot.pins[driver].topPort = .init(rectangle: port.rectangle, layer: port.layer,
            placementX: sink.x - 100, placementY: sink.y - 100, orientation: port.orientation,
            placementStatus: port.placementStatus, use: port.use)
        let result = try fixture.projection.project(snapshot, graph: fixture.graph, budget: fixture.budget)
        let net = try #require(result.network.nets.first { $0.name.value == "a" })
        #expect(Set(net.nodes.map { $0.name.value }) == ["a", "U1:A"])
        #expect(net.totalResistanceOhm == 0 && net.totalGroundCapF == 0)
        let elements = result.network.elements.filter { $0.nodeA.netName.value == "a" }
        #expect(elements.count == 1)
        let short = try #require(elements.first)
        #expect(short.kind == .resistor && short.value == 0 && short.nodeB != short.nodeA)
        let parsed = try SPEFParser().parse(result.spef)
        let parsedNet = try #require(parsed.network(named: "a"))
        #expect(Set(parsedNet.connections.map(\.name)) == ["a", "U1:A"])
    }

    @Test("missing source electrical units refuse instead of inventing a coefficient")
    func missingUnits() async throws {
        let (request, store, geometry) = try await CharacterizedPlacementTests().fixture()
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let bytes = try await store.read(try #require(request.placementTimingProfile).artifact)
        let profile = try sequential(PhysicalDesignJSONCodec().decode(PhysicalDesignPlacementTimingProfile.self, from: bytes))
        var views = inputs.technologyViews
        views["tech"]?.unitDeclarations.resistanceOhms = nil
        let missing = PhysicalDesignProcessInputs(manifest: inputs.manifest, technologyViews: views, cellViews: inputs.cellViews)
        #expect(throws: PhysicalDesignPlacementTimingError.self) {
            try NativePhysicalDesignPlacementRCProjection(profile: profile, inputs: missing, geometry: geometry)
        }
    }

    @Test("projection uses the existing caller work, live and input ceilings", arguments: ["work", "live", "input"])
    func limits(_ kind: String) async throws {
        let fixture = try await fixture()
        let old = fixture.budget.reference
        let limits = PhysicalDesignPlacementTimingReference(artifact: old.artifact,
            maximumInputBytes: kind == "input" ? 1 : old.maximumInputBytes,
            maximumLiveBytes: kind == "live" ? 1 : old.maximumLiveBytes,
            maximumWorkUnits: kind == "work" ? 1 : old.maximumWorkUnits,
            maximumPathWorkUnitsPerAnalysis: kind == "work" ? 1 : old.maximumPathWorkUnitsPerAnalysis,
            maximumPathStates: old.maximumPathStates, maximumEvidenceBytes: old.maximumEvidenceBytes,
            timeoutNanoseconds: old.timeoutNanoseconds)
        let budget = try NativePhysicalDesignPlacementTimingBudget(limits)
        #expect(throws: PhysicalDesignPlacementTimingError.self) {
            try fixture.projection.project(fixture.snapshot, graph: fixture.graph, budget: budget)
        }
    }

    @Test("pre-cancellation propagates through projection")
    func cancellation() async throws {
        let fixture = try await fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.projection.project(fixture.snapshot, graph: fixture.graph, budget: fixture.budget)
        }
        do { _ = try await task.value; Issue.record("Cancelled RC projection returned a result") }
        catch is CancellationError { }
    }

    private func sequential(_ old: PhysicalDesignPlacementTimingProfile,
                            supplies: [STAOperatingSupplyAssumption] = []) throws -> PhysicalDesignPlacementTimingProfile {
        let rc = try STADistributedRCOptions(maximumTimeStep: 1e-12, stopTime: 1e-9, crossingTolerance: 1e-14,
            maximumRefinements: 2, maximumNodes: 8, maximumSteps: 1000)
        return .sourceBoundSequential(manifest: old.manifest, library: old.library, libertyAssetID: old.libertyAssetID,
            capacitanceAssetID: old.capacitanceAssetID, cornerID: old.cornerID, rcCornerID: old.rcCornerID,
            conditionName: old.conditionName, wireLayer: old.wireLayer, wireWidthDBU: old.wireWidthDBU,
            operatingSupplyAssumptions: supplies,
            distributedRC: rc,
            minimumSetupSlackSeconds: old.minimumSetupSlackSeconds)
    }

    private func fixture() async throws -> (projection: NativePhysicalDesignPlacementRCProjection,
        snapshot: PhysicalDesignSnapshot, graph: TimingDesign, budget: NativePhysicalDesignPlacementTimingBudget) {
        let (request, store, geometry) = try await CharacterizedPlacementTests().fixture()
        let reference = try #require(request.placementTimingProfile)
        let bytes = try await store.read(reference.artifact)
        let profile = try sequential(PhysicalDesignJSONCodec().decode(PhysicalDesignPlacementTimingProfile.self, from: bytes))
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let design = try await store.read(request.requireBinding(for: request.design.artifact))
        return (try .init(profile: profile, inputs: inputs, geometry: geometry),
            try #require(request.initialSnapshot), try TimingDesignParser().parse(design, topDesignName: request.design.topDesignName),
            try .init(reference))
    }
}
