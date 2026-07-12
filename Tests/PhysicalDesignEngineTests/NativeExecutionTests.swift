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

    @Test("supported DEF round trip preserves interchange structures")
    func defRoundTrip() throws {
        let snapshot = PhysicalDesignSnapshot(
            topCell: "def_top",
            unitsPerMicron: 1_000,
            die: PhysicalDesignSnapshot.Rect(x: 0, y: 0, width: 20_000, height: 20_000),
            rows: [PhysicalDesignSnapshot.Row(id: "row_0", originX: 1_000, originY: 1_000, siteWidth: 100, height: 1_000, siteCount: 180)],
            cells: [PhysicalDesignSnapshot.Cell(id: "U1", master: "INV_X1", x: 2_000, y: 1_000, width: 1_234, height: 2_345, placed: true)],
            pins: [
                PhysicalDesignSnapshot.Pin(id: "pin_IN", name: "IN", x: 1_000, y: 5_000, netID: "DATA", direction: "input"),
                PhysicalDesignSnapshot.Pin(id: "pin_U1_A", cellID: "U1", name: "A", x: 2_000, y: 1_000, netID: "DATA", direction: "input")
            ],
            nets: [PhysicalDesignSnapshot.Net(id: "DATA", pinIDs: ["pin_IN", "pin_U1_A"])],
            blockages: [PhysicalDesignSnapshot.Rect(x: 5_000, y: 5_000, width: 500, height: 700)],
            powerStructures: [PhysicalDesignSnapshot.PowerStructure(id: "ring_vdd", netID: "VDD", kind: "power", layer: 1, geometry: PhysicalDesignSnapshot.Rect(x: 100, y: 100, width: 19_800, height: 19_800))],
            routes: [PhysicalDesignSnapshot.Route(id: "route_DATA", netID: "DATA", segments: [PhysicalDesignSnapshot.RouteSegment(id: "segment_0", layer: 2, x1: 2_000, y1: 1_000, x2: 3_000, y2: 1_000)])]
        )
        let def = PhysicalDesignDEFWriter().write(snapshot)
        let result = PhysicalDesignDEFParser().parse(Data(def.utf8))

        let parsed = try #require(result.snapshot)
        #expect(result.isValid)
        #expect(parsed.topCell == snapshot.topCell)
        #expect(parsed.die == snapshot.die)
        #expect(parsed.rows == snapshot.rows)
        #expect(parsed.cells == snapshot.cells)
        #expect(parsed.pins.contains { $0.name == "IN" && $0.cellID == nil && $0.netID == "DATA" })
        #expect(parsed.nets.map(\.id) == ["DATA"])
        #expect(parsed.nets[0].pinIDs == ["pin_IN", "pin_U1_A"])
        #expect(parsed.blockages == snapshot.blockages)
        #expect(parsed.powerStructures == snapshot.powerStructures)
        #expect(parsed.routes.count == 1)
        #expect(parsed.routes[0].netID == "DATA")
        #expect(parsed.routes[0].segments[0].layer == 2)
        #expect(parsed.routes[0].segments[0].x1 == 2_000)
        #expect(parsed.routes[0].segments[0].x2 == 3_000)
    }

    @Test("DEF parser reports line and section diagnostics")
    func defParserDiagnostics() throws {
        let input = Data("""
        VERSION 5.8 ;
        DESIGN bad_top ;
        DIEAREA ( 0 0 ) ( 1000 1000 ) ;
        COMPONENTS 1 ;
        - U1 INV_X1 + PLACED ( invalid 0 ) N ;
        END COMPONENTS
        NETS 0 ;
        END NETS
        END DESIGN
        """.utf8)
        let result = PhysicalDesignDEFParser().parse(input)

        #expect(result.snapshot == nil)
        let diagnostic = try #require(result.diagnostics.first { $0.code == "def_integer_invalid" })
        #expect(diagnostic.section == "COMPONENTS")
        #expect(diagnostic.line == 5)
        #expect(diagnostic.severity == .error)
    }

    @Test("retained DEF interchange fixture parses")
    func defFixtureParses() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/positive-interchange.def")
        let data = try Data(contentsOf: fixtureURL)
        let result = PhysicalDesignDEFParser().parse(data)

        #expect(result.isValid)
        #expect(result.snapshot?.topCell == "interchange_top")
        #expect(result.snapshot?.powerStructures.count == 1)
        #expect(result.snapshot?.blockages.count == 1)
    }

    @Test("DEF input execution records source parser provenance")
    func defInputExecution() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let sourceSnapshot = PhysicalDesignFixtureFactory.snapshot()
        let sourceData = Data(PhysicalDesignDEFWriter().write(sourceSnapshot).utf8)
        let sourceReference = try await store.write(
            sourceData,
            relativePath: "inputs/base.def",
            kind: .layout,
            format: .def,
            runID: "source"
        )
        var request = PhysicalDesignFixtureFactory.request(stage: .placement)
        request.inputLayout = PhysicalDesignReference(
            layoutArtifact: sourceReference,
            topCell: sourceSnapshot.topCell,
            layoutDigest: try #require(sourceReference.sha256)
        )

        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)

        #expect(result.status == .completed)
        let manifestReference = try #require(result.payload.runManifest)
        let manifestData = try #require(await store.data(at: manifestReference.path))
        let manifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self, from: manifestData)
        #expect(manifest.sourceLayoutFormat == .def)
        #expect(manifest.sourceLayoutDigest == sourceReference.sha256)
        #expect(manifest.sourceParserID == PhysicalDesignDEFParser.parserID)
        #expect(manifest.sourceParserVersion == PhysicalDesignDEFParser.parserVersion)
        #expect(result.diagnostics.contains { $0.code == "def_core_inferred_from_rows" })
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

    @Test("opaque GDSII input is blocked until an external adapter is qualified")
    func gdsInputIsBlocked() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let engine = PhysicalDesignEngine(artifactStore: store)
        var request = PhysicalDesignFixtureFactory.request(stage: .floorplan)
        request.inputLayout = PhysicalDesignReference(
            layoutArtifact: XcircuiteFileReference(path: "inputs/base.gds", kind: .layout, format: .gdsii),
            topCell: "fixture_top",
            layoutDigest: ""
        )

        let result = try await engine.execute(request)

        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code == "unsupported_layout_format" })
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
