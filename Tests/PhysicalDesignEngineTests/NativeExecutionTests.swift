import Foundation
import Testing
import XcircuitePackage
import PhysicalDesignCLISupport
import FloorplanEngine
@testable import PhysicalDesignCore
@testable import PhysicalDesignEngine

@Suite("PhysicalDesignEngine native execution")
struct NativeExecutionTests {
    @Test("request and snapshot round trip through deterministic JSON")
    func requestRoundTrip() throws {
        let request = PhysicalDesignFixtureFactory.request(stage: .floorplan, snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false))
        let codec = PhysicalDesignJSONCodec()
        let encoded = try codec.encode(request)
        let decoded = try codec.decode(PhysicalDesignRequest.self, from: encoded)
        #expect(decoded == request)
        #expect(try codec.decode(PhysicalDesignSnapshot.self, from: codec.encode(request.initialSnapshot!)) == request.initialSnapshot!)

        let legacyRequest = Data("""
        {"schemaVersion":1,"runID":"legacy","inputs":[],"design":{"artifact":{"path":"design.json","kind":"netlist","format":"JSON"},"topDesignName":"top","designDigest":"\(String(repeating: "b", count: 64))"},"constraints":{"artifact":{"path":"constraints.sdc","kind":"constraint","format":"SDC"},"modeIDs":["func"]},"pdk":{"manifest":{"path":"pdk.json","kind":"technology","format":"JSON"},"processID":"p","version":"1","digest":"\(String(repeating: "c", count: 64))"}}
        """.utf8)
        let legacyDecoded = try codec.decode(PhysicalDesignRequest.self, from: legacyRequest)
        #expect(legacyDecoded.stage == .floorplan)
        #expect(legacyDecoded.configuration == .default)
        let legacyPayload = try codec.decode(
            PhysicalDesignPayload.self,
            from: Data("{\"physicalDesign\":null,\"changedObjectCount\":0,\"candidateActions\":[]}".utf8)
        )
        #expect(legacyPayload.metrics.isEmpty)
    }

    @Test("floorplan emits immutable JSON, DEF and design diff artifacts")
    func floorplanArtifacts() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let engine = PhysicalDesignEngine(artifactStore: store)
        let request = PhysicalDesignFixtureFactory.request(stage: .floorplan, snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false))
        let result = try await engine.execute(request)

        #expect(result.status == .completed)
        #expect(result.artifacts.map(\.format) == [.json, .def, .json, .json])
        #expect(result.payload.changedObjectCount > 0)
        #expect(result.payload.physicalDesign?.layoutDigest.isEmpty == false)

        let revisionReference = try #require(result.payload.physicalDesign?.layoutArtifact)
        let revisionData = try #require(await store.data(at: revisionReference.path))
        let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: revisionData)
        #expect(snapshot.die != nil)
        #expect(snapshot.core != nil)
        #expect(snapshot.rows.isEmpty == false)

        let diffReference = try #require(result.payload.designDiff)
        let diffData = try #require(await store.data(at: diffReference.path))
        let diff = try PhysicalDesignJSONCodec().decode(XcircuiteDesignDiff.self, from: diffData)
        #expect(diff.runID == request.runID)
        #expect(diff.changes.isEmpty == false)

        let manifestReference = try #require(result.payload.runManifest)
        let manifestData = try #require(await store.data(at: manifestReference.path))
        let manifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self, from: manifestData)
        #expect(manifest.validationDiagnostics().isEmpty)
        #expect(manifest.proposedLayout?.layoutDigest == result.payload.physicalDesign?.layoutDigest)
        #expect(manifest.artifacts.count == 3)
    }

    @Test("missing canonical state is blocked with a structured diagnostic")
    func missingSnapshotIsBlocked() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let engine = PhysicalDesignEngine(artifactStore: store)
        let request = PhysicalDesignFixtureFactory.request(stage: .placement)
        let result = try await engine.execute(request)

        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code == "physical_snapshot_missing" })
        #expect(result.artifacts.isEmpty)
    }

    @Test("stage-specific native wrappers reject incompatible requests")
    func stageBoundaryIsEnforced() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let floorplan = NativeFloorplanEngine(artifactStore: store)
        let request = PhysicalDesignFixtureFactory.request(stage: .placement, snapshot: PhysicalDesignFixtureFactory.snapshot())
        let result = try await floorplan.execute(request)
        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code == "stage_mismatch" })
    }

    @Test("all declared native stages execute with their typed prerequisites")
    func allStagesExecute() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let engine = PhysicalDesignEngine(artifactStore: store)
        let stages: [PhysicalDesignStage] = [
            .floorplan,
            .powerPlanning,
            .placement,
            .clockTreeSynthesis,
            .globalRouting,
            .detailedRouting,
            .antennaRepair,
            .fillInsertion,
            .redundantViaInsertion,
            .hotspotRepair
        ]
        for stage in stages {
            var configuration = PhysicalDesignConfiguration.default
            if stage == .antennaRepair {
                configuration.maximumAntennaRatio = 300
            }
            let result = try await engine.execute(
                PhysicalDesignFixtureFactory.request(
                    stage: stage,
                    snapshot: PhysicalDesignFixtureFactory.snapshot(),
                    configuration: configuration
                )
            )
            #expect(result.status == .completed, "stage \(stage.rawValue) should complete")
            #expect(result.payload.physicalDesign != nil)
        }

        var ecoConfiguration = PhysicalDesignConfiguration.default
        ecoConfiguration.ecoTargetCellID = "U1"
        ecoConfiguration.ecoAction = .resizeCell
        let ecoResult = try await engine.execute(
            PhysicalDesignFixtureFactory.request(stage: .timingECO, snapshot: PhysicalDesignFixtureFactory.snapshot(), configuration: ecoConfiguration)
        )
        #expect(ecoResult.status == .completed)

        var drcConfiguration = PhysicalDesignConfiguration.default
        drcConfiguration.ecoAction = .addBlockage
        let drcResult = try await engine.execute(
            PhysicalDesignFixtureFactory.request(stage: .drcRepair, snapshot: PhysicalDesignFixtureFactory.snapshot(), configuration: drcConfiguration)
        )
        #expect(drcResult.status == .completed)
    }

    @Test("CLI returns a deterministic structured error for invalid options")
    func cliErrorIsStructured() async throws {
        let command = PhysicalDesignCLICommand()
        let output = await command.run(arguments: ["--unknown"])
        let decoded = try PhysicalDesignJSONCodec().decode(PhysicalDesignCLIErrorOutput.self, from: Data(output.utf8))
        #expect(decoded.status == "failed")
        #expect(decoded.code == "unknown_option")
    }
}
