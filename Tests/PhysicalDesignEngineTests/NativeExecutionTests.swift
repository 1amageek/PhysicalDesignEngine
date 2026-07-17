import Foundation
import Testing
import CircuiteFoundation
import LogicIR
import PDKCore
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

    }

    @Test("rejects a design handoff with mismatched provenance input")
    func rejectsMismatchedDesignProvenance() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var request = PhysicalDesignFixtureFactory.request(
            stage: .floorplan,
            snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
        )
        request.design.provenance = LogicDesignProvenance(
            sourceDesignDigest: "source",
            inputDesignDigest: "different",
            transformationID: "mapped",
            producerID: "test-producer",
            producerVersion: "1.0.0"
        )

        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)

        #expect(result.status == .blocked)
        let diagnosticCodes = result.diagnostics.map(\.code.rawValue)
        #expect(diagnosticCodes.contains("DESIGN_PROVENANCE_INPUT_DIGEST_MISMATCH"))
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
        let diff = try PhysicalDesignJSONCodec().decode(PhysicalDesignDesignDiff.self, from: diffData)
        #expect(diff.runID == request.runID)
        #expect(diff.changes.isEmpty == false)

        let manifestReference = try #require(result.payload.runManifest)
        let manifestData = try #require(await store.data(at: manifestReference.path))
        let manifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self, from: manifestData)
        #expect(manifest.validationDiagnostics().isEmpty)
        #expect(manifest.proposedLayout?.layoutDigest == result.payload.physicalDesign?.layoutDigest)
        #expect(manifest.artifacts.count == 3)
    }

    @Test("review packet round trip validates current artifacts")
    func reviewPacketRoundTripAndCurrentArtifactsValidate() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(
                stage: .floorplan,
                snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
            )
        )
        let manifestReference = try #require(result.payload.runManifest)
        let validator = PhysicalDesignArtifactReviewValidator(artifactStore: store)
        let packet = try await validator.preparePacket(manifestReference: manifestReference)
        let codec = PhysicalDesignJSONCodec()
        let decodedPacket = try codec.decode(PhysicalDesignReviewPacket.self, from: codec.encode(packet))
        #expect(decodedPacket.runID == packet.runID)
        #expect(decodedPacket.stage == packet.stage)
        #expect(decodedPacket.manifestDigest == packet.manifestDigest)
        #expect(decodedPacket.proposedLayout == packet.proposedLayout)
        #expect(decodedPacket.artifactDigests == packet.artifactDigests)
        #expect(decodedPacket.reviewScope == packet.reviewScope)
        let diagnostics = await validator.validateCurrentArtifacts(packet)
        #expect(diagnostics.isEmpty)
    }

    @Test("review packet rejects altered embedded manifests")
    func reviewPacketRejectsAlteredEmbeddedManifest() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(
                stage: .floorplan,
                snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
            )
        )
        let manifestReference = try #require(result.payload.runManifest)
        let validator = PhysicalDesignArtifactReviewValidator(artifactStore: store)
        let packet = try await validator.preparePacket(manifestReference: manifestReference)
        var alteredPacket = packet
        alteredPacket.manifest.implementationVersion = "tampered"
        let diagnostics = await validator.validateCurrentArtifacts(alteredPacket)
        #expect(diagnostics.contains { $0.code.rawValue == "physical_design_review_artifacts_stale" })
    }

    @Test("review preparation rejects tampered immutable artifacts")
    func reviewPreparationRejectsTamperedArtifact() async throws {
        let baseStore = InMemoryPhysicalDesignArtifactStore()
        let store = TamperingPhysicalDesignArtifactStore(base: baseStore)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(
                stage: .floorplan,
                snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
            )
        )
        let manifestReference = try #require(result.payload.runManifest)
        let layoutReference = try #require(result.payload.physicalDesign?.layoutArtifact)
        await store.setTamperedPath(layoutReference.path)

        do {
            _ = try await PhysicalDesignArtifactReviewValidator(artifactStore: store).preparePacket(
                manifestReference: manifestReference
            )
            Issue.record("Tampered artifact unexpectedly produced a review packet")
        } catch let error as PhysicalDesignArtifactReviewError {
            guard case .artifactReadFailed = error else {
                Issue.record("Unexpected artifact review error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected artifact review error: \(error)")
        }
    }

    @Test("artifact validation rejects tampered current bytes")
    func artifactValidationRejectsTamperedCurrentArtifact() async throws {
        let baseStore = InMemoryPhysicalDesignArtifactStore()
        let store = TamperingPhysicalDesignArtifactStore(base: baseStore)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(
                stage: .floorplan,
                snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
            )
        )
        let manifestReference = try #require(result.payload.runManifest)
        let validator = PhysicalDesignArtifactReviewValidator(artifactStore: store)
        let packet = try await validator.preparePacket(manifestReference: manifestReference)
        await store.setTamperedPath(packet.proposedLayout.layoutArtifact.path)
        let diagnostics = await validator.validateCurrentArtifacts(packet)
        #expect(diagnostics.contains { $0.code.rawValue == "physical_design_review_artifacts_unavailable" })
    }

    @Test("artifact validation rejects a stale packet")
    func artifactValidationRejectsStalePacket() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(
                stage: .floorplan,
                snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
            )
        )
        let manifestReference = try #require(result.payload.runManifest)
        let validator = PhysicalDesignArtifactReviewValidator(artifactStore: store)
        let packet = try await validator.preparePacket(manifestReference: manifestReference)
        var alteredPacket = packet
        alteredPacket.manifest.implementationVersion = "tampered"
        let diagnostics = await validator.validateCurrentArtifacts(alteredPacket)
        #expect(diagnostics.contains { $0.code.rawValue == "physical_design_review_artifacts_stale" })
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
            routes: [PhysicalDesignSnapshot.Route(id: "route_DATA", netID: "DATA", segments: [PhysicalDesignSnapshot.RouteSegment(id: "segment_0", layer: 2, x1: 2_000, y1: 1_000, x2: 3_000, y2: 1_000)])],
            implementationState: PhysicalDesignImplementationState(
                tracks: [PhysicalDesignImplementationState.Track(id: "track_M2_X", layer: 2, direction: "vertical", origin: 1_000, spacing: 100, count: 180)],
                pads: [PhysicalDesignImplementationState.Pad(id: "pad_pin_IN", pinID: "pin_IN", side: "left", geometry: PhysicalDesignSnapshot.Rect(x: 0, y: 5_000, width: 100, height: 100), placed: true)]
            )
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
        #expect(parsed.implementationState?.tracks == snapshot.implementationState?.tracks)
        #expect(parsed.implementationState?.pads == snapshot.implementationState?.pads)
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
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "positive-interchange",
                withExtension: "def",
                subdirectory: "Fixtures"
            )
        )
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
            layoutDigest: sourceReference.digest.hexadecimalValue
        )

        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)

        #expect(result.status == .completed)
        let manifestReference = try #require(result.payload.runManifest)
        let manifestData = try #require(await store.data(at: manifestReference.path))
        let manifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self, from: manifestData)
        #expect(manifest.sourceLayoutFormat == .def)
        #expect(manifest.sourceLayoutDigest == sourceReference.digest.hexadecimalValue)
        #expect(manifest.sourceParserID == PhysicalDesignDEFParser.parserID)
        #expect(manifest.sourceParserVersion == PhysicalDesignDEFParser.parserVersion)
        #expect(result.diagnostics.contains { $0.code.rawValue == "def_core_inferred_from_rows" })
    }

    @Test("floorplan persists implementation state for IO, power and routing constraints")
    func floorplanImplementationState() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let snapshot = PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .floorplan, snapshot: snapshot)
        )

        #expect(result.status == .completed)
        let revision = try #require(result.payload.physicalDesign)
        let data = try #require(await store.data(at: revision.layoutArtifact.path))
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: data)
        #expect(output.implementationState?.tracks.isEmpty == false)
        #expect(output.implementationState?.powerDomains.count == 1)
        #expect(output.implementationState?.pads.isEmpty == true)
    }

    @Test("placement emits legal placement proof and avoids blockages")
    func placementProof() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var snapshot = PhysicalDesignFixtureFactory.snapshot(includeFloorplan: true, includePlacement: false, includeRoutes: false, includeVias: false, includeHotspot: false)
        snapshot.rows = [PhysicalDesignSnapshot.Row(id: "row_0", originX: 10_000, originY: 10_000, siteWidth: 100, height: 1_000, siteCount: 100)]
        snapshot.blockages = [PhysicalDesignSnapshot.Rect(x: 10_000, y: 10_000, width: 100, height: 1_000)]
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .placement, snapshot: snapshot)
        )

        #expect(result.status == .completed)
        let revision = try #require(result.payload.physicalDesign)
        let data = try #require(await store.data(at: revision.layoutArtifact.path))
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: data)
        let proof = try #require(output.implementationState?.placementProof)
        #expect(proof.legalCellCount == proof.cellCount)
        #expect(proof.blockageConflictCount > 0)
        #expect(output.cells.allSatisfy { $0.placed })
        #expect(output.cells.allSatisfy { cell in
            !snapshot.blockages.contains { $0.intersects(PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)) }
        })
    }

    @Test("CTS materializes clock buffers, branch nets and route constraints")
    func ctsMaterialization() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .clockTreeSynthesis, snapshot: PhysicalDesignFixtureFactory.snapshot())
        )
        #expect(result.status == .completed)
        let revision = try #require(result.payload.physicalDesign)
        let data = try #require(await store.data(at: revision.layoutArtifact.path))
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: data)
        #expect(output.cells.contains { $0.isClockBuffer })
        #expect(output.nets.contains { $0.id.hasPrefix("CLK_branch_") && $0.isClock })
        #expect(output.implementationState?.clockRouteConstraints.isEmpty == false)
        #expect(output.implementationState?.clockRouteConstraints.allSatisfy { $0.maximumLength == 40_000 } == true)
        #expect(output.clockTrees.contains { !$0.bufferCellIDs.isEmpty })
        #expect(output.clockTrees.allSatisfy { $0.longestPathLengthDBU >= $0.shortestPathLengthDBU })
        #expect(output.clockTrees.allSatisfy { $0.timingEstimate == nil })
        #expect(result.payload.claims.geometry == .verified)
        #expect(result.payload.claims.timing == .blocked)
        #expect(result.payload.claims.production == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == "cts_timing_characterization_missing" })
        #expect(output.routes.contains { $0.netID == "CLK" })
        #expect(output.routes.contains { $0.netID.hasPrefix("CLK_branch_") })
        #expect(output.routes.flatMap(\.segments).allSatisfy { segment in
            segment.x1 != segment.x2 || segment.y1 != segment.y2
        })
    }

    @Test("CTS timing estimates require verified PDK RC cell and corner characterization")
    func characterizedCTSTiming() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let pdk = try await store.registerInput(
            Data("pdk".utf8),
            relativePath: "inputs/characterized-pdk.json",
            kind: .technology,
            format: .json
        )
        let rc = try await store.registerInput(
            Data("rc".utf8),
            relativePath: "inputs/clock-rc.json",
            kind: try ArtifactKind(rawValue: "technology.rc"),
            format: .json
        )
        let library = try await store.registerInput(
            Data("library".utf8),
            relativePath: "inputs/clock.lib",
            kind: try ArtifactKind(rawValue: "timing.library"),
            format: .liberty
        )
        let model = PhysicalDesignClockTimingModel(
            processID: "fixture-130nm",
            pdkVersion: "1",
            cornerID: "typical",
            pdkManifestDigest: pdk.digest.hexadecimalValue,
            rcModelDigest: rc.digest.hexadecimalValue,
            cellLibraryDigest: library.digest.hexadecimalValue,
            wireDelaySamples: [
                .init(pathLengthDBU: 0, delayPS: 0),
                .init(pathLengthDBU: 20_000, delayPS: 40),
            ],
            cellDelays: [.init(master: "CLKBUF_X1", delayPS: 5)]
        )
        let modelData = try PhysicalDesignJSONCodec().encode(model)
        let modelArtifact = try await store.registerInput(
            modelData,
            relativePath: "inputs/clock-timing-model.json",
            kind: try ArtifactKind(rawValue: "timing.characterization"),
            format: .json
        )
        let modelReference = PhysicalDesignClockTimingModelReference(
            modelArtifact: modelArtifact,
            pdkManifestArtifact: pdk,
            rcModelArtifact: rc,
            cellLibraryArtifact: library,
            processID: "fixture-130nm",
            pdkVersion: "1",
            cornerID: "typical"
        )
        var request = PhysicalDesignFixtureFactory.request(
            stage: .clockTreeSynthesis,
            snapshot: PhysicalDesignFixtureFactory.snapshot()
        )
        request.inputs = [modelArtifact, pdk, rc, library]
        request.pdk = PDKReference(
            manifest: pdk,
            processID: "fixture-130nm",
            version: "1",
            digest: pdk.digest.hexadecimalValue
        )
        request.executionIntent = .characterizedTiming
        request.clockTimingModel = modelReference

        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)

        #expect(result.status == .completed)
        #expect(result.payload.claims.timing == .verified)
        #expect(result.payload.claims.production == .blocked)
        let revision = try #require(result.payload.physicalDesign)
        let data = try #require(await store.data(at: revision.layoutArtifact.path))
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: data)
        let estimate = try #require(output.clockTrees.first?.timingEstimate)
        #expect(estimate.cornerID == "typical")
        #expect(estimate.estimatedLatencyPS > 0)
        #expect(estimate.modelDigest == modelArtifact.digest.hexadecimalValue)
    }

    @Test("execution intent does not encode flow authority")
    func executionIntentDoesNotEncodeFlowAuthority() throws {
        let data = try #require("\"productionEligible\"".data(using: .utf8))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PhysicalDesignExecutionIntent.self, from: data)
        }
    }

    @Test("routing records layer, spacing and antenna evidence")
    func routingEvidence() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .globalRouting, snapshot: PhysicalDesignFixtureFactory.snapshot())
        )

        #expect(result.status == .completed)
        let revision = try #require(result.payload.physicalDesign)
        let data = try #require(await store.data(at: revision.layoutArtifact.path))
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: data)
        let evidence = try #require(output.implementationState?.routingEvidence)
        #expect(evidence.routedNetCount == output.routes.count)
        #expect(evidence.antennaRiskNetIDs == ["DATA"])
        #expect(evidence.viaCount > 0)
        #expect(output.routes.flatMap(\.segments).contains { $0.layer % 2 == 1 })
        #expect(output.routes.flatMap(\.segments).contains { $0.layer % 2 == 0 })
        #expect(output.routes.flatMap(\.segments).allSatisfy { $0.x1 == $0.x2 || $0.y1 == $0.y2 })
    }

    @Test("routing fails closed on blockage conflicts")
    func routingBlockageDiagnostic() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var snapshot = PhysicalDesignFixtureFactory.snapshot()
        snapshot.blockages = [PhysicalDesignSnapshot.Rect(x: 19_000, y: 9_000, width: 13_000, height: 4_000)]
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .globalRouting, snapshot: snapshot)
        )

        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == "routing_blockage_conflict" })
        #expect(result.artifacts.isEmpty)
    }

    @Test("power planning materializes connected power nets and vias")
    func powerPlanningMaterializesConnectivity() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .powerPlanning, snapshot: PhysicalDesignFixtureFactory.snapshot(includeRoutes: false, includeVias: false))
        )

        #expect(result.status == .completed)
        let reference = try #require(result.payload.physicalDesign)
        let data = try #require(await store.data(at: reference.layoutArtifact.path))
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: data)
        #expect(output.powerStructures.contains { $0.kind == "ring" })
        #expect(output.powerStructures.contains { $0.kind == "strap" })
        #expect(output.powerStructures.contains { $0.kind == "rail" })
        #expect(output.vias.contains { $0.netID == "VDD" })
        #expect(output.vias.contains { $0.netID == "VSS" })
        #expect(output.nets.first { $0.id == "VDD" }?.pinIDs.count == 2)
        #expect(output.nets.first { $0.id == "VSS" }?.pinIDs.count == 2)
    }

    @Test("buffer ECO splits connectivity and reroutes both branches")
    func bufferEcoSplitsAndReroutesNet() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var configuration = PhysicalDesignFixtureFactory.configuration
        configuration.ecoAction = .bufferInsertion
        configuration.ecoTargetNetID = "DATA"
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(
                stage: .timingECO,
                snapshot: PhysicalDesignFixtureFactory.snapshot(includeRoutes: false, includeVias: false),
                configuration: configuration
            )
        )

        #expect(result.status == .completed)
        let reference = try #require(result.payload.physicalDesign)
        let data = try #require(await store.data(at: reference.layoutArtifact.path))
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: data)
        let bufferID = "eco_buf_DATA"
        #expect(output.cells.contains { $0.id == bufferID && $0.placed })
        #expect(output.nets.contains { $0.id == "DATA_eco_branch" })
        #expect(output.nets.first { $0.id == "DATA" }?.pinIDs.contains("pin_\(bufferID)_A") == true)
        #expect(output.nets.first { $0.id == "DATA_eco_branch" }?.pinIDs.contains("pin_\(bufferID)_Y") == true)
        #expect(output.routes.contains { $0.netID == "DATA" })
        #expect(output.routes.contains { $0.netID == "DATA_eco_branch" })
    }

    @Test("illegal ECO movement is blocked without an artifact")
    func illegalEcoMovementIsBlocked() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var configuration = PhysicalDesignFixtureFactory.configuration
        configuration.ecoAction = .moveCell
        configuration.ecoTargetCellID = "U1"
        configuration.ecoDeltaX = 10_000
        configuration.ecoDeltaY = 1_000
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .timingECO, snapshot: PhysicalDesignFixtureFactory.snapshot(), configuration: configuration)
        )

        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == "eco_move_illegal" })
        #expect(result.artifacts.isEmpty)
    }

    @Test("repair strategies persist verified proof evidence")
    func repairProofs() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var ecoConfiguration = PhysicalDesignFixtureFactory.configuration
        ecoConfiguration.ecoTargetCellID = "U1"
        ecoConfiguration.ecoAction = .resizeCell
        let ecoResult = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .timingECO, snapshot: PhysicalDesignFixtureFactory.snapshot(), configuration: ecoConfiguration)
        )
        #expect(ecoResult.status == .completed)
        let ecoReference = try #require(ecoResult.payload.physicalDesign)
        let ecoData = try #require(await store.data(at: ecoReference.layoutArtifact.path))
        let ecoOutput = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: ecoData)
        #expect(ecoOutput.implementationState?.repairProofs.contains { $0.stage == PhysicalDesignStage.timingECO.rawValue && $0.verified } == true)

        var antennaConfiguration = PhysicalDesignFixtureFactory.configuration
        antennaConfiguration.repairConstraints = PhysicalDesignRepairConstraints(antennaStrategy: .protectionDevice)
        let antennaResult = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .antennaRepair, snapshot: PhysicalDesignFixtureFactory.snapshot(), configuration: antennaConfiguration)
        )
        #expect(antennaResult.status == .completed)
        let antennaReference = try #require(antennaResult.payload.physicalDesign)
        let antennaData = try #require(await store.data(at: antennaReference.layoutArtifact.path))
        let antennaOutput = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: antennaData)
        #expect(antennaOutput.cells.contains { $0.master == "ANTENNA_DIODE" })
        #expect(antennaOutput.antennaRepairs.contains { $0.strategy == PhysicalDesignAntennaRepairStrategy.protectionDevice.rawValue })
        #expect(antennaOutput.implementationState?.repairProofs.contains { $0.stage == PhysicalDesignStage.antennaRepair.rawValue && $0.verified } == true)
    }

    @Test("fill, redundant-via and hotspot repairs are constrained and proven")
    func dfmRepairProofs() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var fillSnapshot = PhysicalDesignFixtureFactory.snapshot()
        fillSnapshot.blockages = [PhysicalDesignSnapshot.Rect(x: 40_000, y: 40_000, width: 10_000, height: 10_000)]
        let fillResult = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .fillInsertion, snapshot: fillSnapshot)
        )
        #expect(fillResult.status == .completed)
        let fillReference = try #require(fillResult.payload.physicalDesign)
        let fillData = try #require(await store.data(at: fillReference.layoutArtifact.path))
        let fillOutput = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: fillData)
        #expect(fillOutput.fills.isEmpty == false)
        #expect(fillOutput.implementationState?.repairProofs.contains { $0.stage == PhysicalDesignStage.fillInsertion.rawValue && $0.verified } == true)
        #expect(fillOutput.fills.allSatisfy { fill in !fillSnapshot.blockages.contains { $0.intersects(fill.geometry) } })

        let viaResult = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .redundantViaInsertion, snapshot: PhysicalDesignFixtureFactory.snapshot())
        )
        #expect(viaResult.status == .completed)
        let viaReference = try #require(viaResult.payload.physicalDesign)
        let viaData = try #require(await store.data(at: viaReference.layoutArtifact.path))
        let viaOutput = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: viaData)
        #expect(viaOutput.vias.count > 1)
        #expect(viaOutput.implementationState?.repairProofs.contains { $0.stage == PhysicalDesignStage.redundantViaInsertion.rawValue && $0.verified } == true)

        let hotspotResult = try await PhysicalDesignEngine(artifactStore: store).execute(
            PhysicalDesignFixtureFactory.request(stage: .hotspotRepair, snapshot: PhysicalDesignFixtureFactory.snapshot())
        )
        #expect(hotspotResult.status == .completed)
        let hotspotReference = try #require(hotspotResult.payload.physicalDesign)
        let hotspotData = try #require(await store.data(at: hotspotReference.layoutArtifact.path))
        let hotspotOutput = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: hotspotData)
        #expect(hotspotOutput.hotspots.allSatisfy { $0.resolved })
        #expect(hotspotOutput.implementationState?.repairProofs.contains { $0.stage == PhysicalDesignStage.hotspotRepair.rawValue && $0.verified } == true)
    }

    @Test("missing canonical state is blocked with a structured diagnostic")
    func missingSnapshotIsBlocked() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let engine = PhysicalDesignEngine(artifactStore: store)
        let request = PhysicalDesignFixtureFactory.request(stage: .placement)
        let result = try await engine.execute(request)

        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == "physical_snapshot_missing" })
        #expect(result.artifacts.isEmpty)
    }

    @Test("opaque GDSII input is blocked until a dedicated decoder is available")
    func gdsInputIsBlocked() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let engine = PhysicalDesignEngine(artifactStore: store)
        var request = PhysicalDesignFixtureFactory.request(stage: .floorplan)
        request.inputLayout = PhysicalDesignReference(
            layoutArtifact: PhysicalDesignFixtureFactory.artifact(
                path: "inputs/base.gds",
                kind: .layout,
                format: .gdsii,
                role: .input
            ),
            topCell: "fixture_top",
            layoutDigest: ""
        )

        let result = try await engine.execute(request)

        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == "unsupported_layout_format" })
    }

    @Test("input artifact integrity failure is blocked before mutation")
    func inputArtifactIntegrityFailureIsBlocked() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let snapshotData = try PhysicalDesignJSONCodec().encode(PhysicalDesignFixtureFactory.snapshot())
        let storedReference = try await store.write(
            snapshotData,
            relativePath: "inputs/base.json",
            kind: .layout,
            format: .json,
            runID: "input-fixture"
        )
        let tamperedArtifact = ArtifactReference(
            id: storedReference.id,
            locator: storedReference.locator,
            digest: storedReference.digest,
            byteCount: storedReference.byteCount + 1,
            producer: storedReference.producer
        )
        var request = PhysicalDesignFixtureFactory.request(stage: .floorplan)
        request.inputLayout = PhysicalDesignReference(
            layoutArtifact: tamperedArtifact,
            topCell: "fixture_top",
            layoutDigest: storedReference.digest.hexadecimalValue
        )

        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)

        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == "physical_input_artifact_invalid" })
        #expect(result.artifacts.isEmpty)
    }

    @Test("snapshot validation reports overflowing row geometry")
    func snapshotValidationReportsOverflow() {
        let snapshot = PhysicalDesignSnapshot(
            topCell: "overflow_fixture",
            rows: [PhysicalDesignSnapshot.Row(
                id: "row_overflow",
                originX: Int64.max,
                originY: 0,
                siteWidth: 2,
                height: 1,
                siteCount: Int64.max
            )]
        )

        #expect(snapshot.validationDiagnostics().contains { $0.contains("row row_overflow has invalid geometry") })
        #expect(PhysicalDesignSnapshot.Rect(x: Int64.max, y: 0, width: 2, height: 1).maxX == Int64.max)
    }

    @Test("stage-specific native wrappers reject incompatible requests")
    func stageBoundaryIsEnforced() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let floorplan = NativeFloorplanEngine(artifactStore: store)
        let request = PhysicalDesignFixtureFactory.request(stage: .placement, snapshot: PhysicalDesignFixtureFactory.snapshot())
        let result = try await floorplan.execute(request)
        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == "stage_mismatch" })
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
            var configuration = PhysicalDesignFixtureFactory.configuration
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

        var ecoConfiguration = PhysicalDesignFixtureFactory.configuration
        ecoConfiguration.ecoTargetCellID = "U1"
        ecoConfiguration.ecoAction = .resizeCell
        let ecoResult = try await engine.execute(
            PhysicalDesignFixtureFactory.request(stage: .timingECO, snapshot: PhysicalDesignFixtureFactory.snapshot(), configuration: ecoConfiguration)
        )
        #expect(ecoResult.status == .completed)

        var drcConfiguration = PhysicalDesignFixtureFactory.configuration
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
