import Foundation
import Testing
import PhysicalDesignEngine
@testable import PhysicalDesignCore

@Suite("Native ECO geometry admission")
struct ECOGeometryAdmissionTests {
    @Test("crossing a retained conductor rejects the same-design candidate without artifacts", .timeLimit(.minutes(1)))
    func crossingBlockageIsAtomic() async throws {
        let fixture = try await prepared()
        let input = try #require(fixture.request.initialSnapshot)
        let codec = PhysicalDesignJSONCodec()
        let before = try codec.encode(input)
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(fixture.request)
        #expect(result.status == .blocked, "\(result.diagnostics)")
        #expect(result.diagnostics.contains { $0.code.rawValue == "eco_blockage_route_intersection" })
        #expect(result.artifactBindings.isEmpty && result.payload.physicalDesign == nil)
        #expect(try codec.encode(try #require(fixture.request.initialSnapshot)) == before)
        #expect(await fixture.store.data(at: "runs/eco-blockage/physical-design/drc_repair/revision.json") == nil)
    }

    @Test("disjoint constraint changes retain geometry and tree topology while invalidating dependent proof", .timeLimit(.minutes(1)))
    func disjointInvalidation() async throws {
        var fixture = try await prepared(y: 1100)
        var input = try #require(fixture.request.initialSnapshot)
        input.nets[0].isClock = true
        input.clockTrees = [.init(id: "tree", netID: "N", sourcePinID: "U1/Y", sinkPinIDs: ["U2/A"],
            shortestPathLengthDBU: 6000, longestPathLengthDBU: 6000,
            timingEstimate: .init(cornerID: "retained", estimatedSkewPS: 0, estimatedLatencyPS: 10,
                modelDigest: "old-model", pdkManifestDigest: "old-pdk", rcModelDigest: "old-rc", cellLibraryDigest: "old-library"))]
        input.implementationState?.routingEvidence = .init(mode: "old", routedNetCount: 1)
        input.implementationState?.repairProofs = [oldProof()]
        fixture.request.initialSnapshot = input
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(fixture.request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
            from: await fixture.store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        #expect(output.routes == input.routes && output.vias == input.vias && output.pins == input.pins && output.nets == input.nets)
        #expect(output.clockTrees[0].id == input.clockTrees[0].id && output.clockTrees[0].sinkPinIDs == input.clockTrees[0].sinkPinIDs)
        #expect(output.clockTrees[0].timingEstimate == nil && output.clockTrees[0].shortestPathLengthDBU == nil && output.clockTrees[0].longestPathLengthDBU == nil)
        #expect(input.clockTrees[0].timingEstimate != nil && input.implementationState?.repairProofs == [oldProof()])
        #expect(output.implementationState?.routingEvidence == nil)
        let proofs = try #require(output.implementationState?.repairProofs)
        #expect(proofs.count == 1 && proofs[0].strategy == "add_blockage" && proofs[0].verified)
        #expect(result.payload.claims.geometry == .verified && result.payload.claims.timing == .notApplicable && result.payload.claims.production == .blocked)
        for artifact in result.artifactBindings { _ = try await fixture.store.read(artifact) }
    }

    @Test("actual caps and exact contact metal respect shared native layer applicability", .timeLimit(.minutes(1)))
    func exactGeometry() async throws {
        let fixture = try await prepared()
        var input = try #require(fixture.request.initialSnapshot)
        input.blockages = [.init(x: 2500, y: 1250, width: 500, height: 1000)]
        input.routes[0].segments[0].x2 = 2450
        try PhysicalDesignSourceRouter.validateRetainedBlockages(input, configuration: fixture.request.configuration, geometry: fixture.geometry)
        input.routes[0].segments[0].x2 = 2451
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try PhysicalDesignSourceRouter.validateRetainedBlockages(input, configuration: fixture.request.configuration, geometry: fixture.geometry)
        }
        input.routes = []
        input.vias = [.init(id: "contact", netID: "N", x: 2450, y: 1500, lowerLayer: 2, upperLayer: 3, master: "hv")]
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try PhysicalDesignSourceRouter.validateRetainedBlockages(input, configuration: fixture.request.configuration, geometry: fixture.geometry)
        }
        input.vias[0].x = 2400
        try PhysicalDesignSourceRouter.validateRetainedBlockages(input, configuration: fixture.request.configuration, geometry: fixture.geometry)
        input.vias = []
        input.routes = [.init(id: "unselected", netID: "N", segments: [.init(id: "vertical", layer: 3, x1: 2700, y1: 1100, x2: 2700, y2: 2300, widthDBU: 100)])]
        var onlyHorizontal = fixture.request.configuration; onlyHorizontal.preferredRoutingLayers = [2]
        try PhysicalDesignSourceRouter.validateRetainedBlockages(input, configuration: onlyHorizontal, geometry: fixture.geometry)
    }

    @Test("missing facts and explicit work ceilings cannot publish an ECO success", .timeLimit(.minutes(1)), arguments: ["width", "budget", "core", "via", "retained-conflict"])
    func boundedRefusal(_ scenario: String) async throws {
        var fixture = try await prepared(y: 1100)
        switch scenario {
        case "width": fixture.request.initialSnapshot?.routes[0].segments[0].widthDBU = nil
        case "budget": fixture.request.configuration.maximumRoutingCandidateChecks = 1
        case "via": fixture.request.initialSnapshot?.vias = [.init(id: "contact", netID: "N", x: 2450, y: 1500, lowerLayer: 2, upperLayer: 3, master: "hv")]
        case "retained-conflict":
            fixture.request.initialSnapshot?.blockages = [.init(x: 2500, y: 1000, width: 500, height: 1000)]
            fixture.request.configuration.ecoAction = .moveCell
            fixture.request.configuration.ecoTargetCellID = "U1"
        default: fixture.request.configuration.rowHeight = 10000
        }
        let before = try PhysicalDesignJSONCodec().encode(try #require(fixture.request.initialSnapshot))
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(fixture.request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil, "\(result.diagnostics)")
        let code: String
        switch scenario {
        case "width": code = "eco_blockage_width_missing"
        case "budget": code = "routing_candidate_budget_exhausted"
        case "via", "retained-conflict": code = "eco_blockage_route_intersection"
        default: code = "eco_blockage_core_conflict"
        }
        #expect(result.diagnostics.contains { $0.code.rawValue == code })
        #expect(try PhysicalDesignJSONCodec().encode(try #require(fixture.request.initialSnapshot)) == before)
    }

    @Test("cancelled actual API invocation preserves its accepted source snapshot", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        let fixture = try await prepared()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PhysicalDesignEngine(artifactStore: fixture.store).execute(fixture.request)
        }
        let result = try await task.value
        #expect(result.status == .cancelled && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil)
        #expect(fixture.request.initialSnapshot?.blockages.isEmpty == true)
    }

    @Test("changed routing invalidates old repair evidence, stable geometry retains it", .timeLimit(.minutes(1)))
    func routingInvalidation() async throws {
        var fixture = try await prepared()
        fixture.request.stage = .globalRouting
        var input = try #require(fixture.request.initialSnapshot)
        input.implementationState?.repairProofs = [oldProof()]
        let direct = try PhysicalDesignSourceRouter().route(input, configuration: fixture.request.configuration,
            mode: "direct", onlyNetID: nil, geometry: fixture.geometry)
        #expect(direct.snapshot.implementationState?.repairProofs.isEmpty == true)
        let changed = await PhysicalDesignNativeMutationEngine().applyPrepared(fixture.request, to: input, processGeometry: fixture.geometry)
        #expect(changed.status == .completed, "\(changed.diagnostics)")
        var output = try #require(changed.snapshot)
        #expect(output.routes != input.routes && output.implementationState?.repairProofs.isEmpty == true)
        #expect(output.implementationState?.routingEvidence != nil)
        output.implementationState?.repairProofs = [oldProof()]
        let stable = await PhysicalDesignNativeMutationEngine().applyPrepared(fixture.request, to: output, processGeometry: fixture.geometry)
        let unchanged = try #require(stable.snapshot)
        #expect(stable.status == .completed && unchanged.routes == output.routes && unchanged.vias == output.vias)
        #expect(unchanged.implementationState?.repairProofs == [oldProof()])
    }

    private func oldProof() -> PhysicalDesignImplementationState.RepairProof {
        .init(stage: "drc-repair", strategy: "previous-candidate", targetIDs: [], violationsBefore: 0, violationsAfter: 0, verified: true)
    }

    private func prepared(y: Int64 = 1500) async throws -> Fixture {
        let support = ProcessGeometryTests()
        let (geometry, base, store) = try await support.fixture(routingPorts: true)
        var request = support.nativeRequest(base)
        request.runID = "eco-blockage"; request.stage = .drcRepair; request.configuration.ecoAction = .addBlockage
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        snapshot.die = .init(x: 0, y: 0, width: 10000, height: 5000)
        snapshot.core = snapshot.die
        snapshot.cells = [.init(id: "U1", master: "INV_X1", x: 0, y: 1000, width: 2000, height: 1000, placed: true),
            .init(id: "U2", master: "INV_X1", x: 7000, y: 1000, width: 2000, height: 1000, placed: true)]
        snapshot.pins = [.init(id: "U1/Y", cellID: "U1", name: "Y", x: 1500, y: y, netID: "N", direction: "output", accessLayer: 2),
            .init(id: "U2/A", cellID: "U2", name: "A", x: 7500, y: y, netID: "N", direction: "input", accessLayer: 2)]
        snapshot.nets = [.init(id: "N", pinIDs: ["U1/Y", "U2/A"])]
        snapshot.rows = [.init(id: "row", originX: 0, originY: 1000, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit")]
        snapshot.routes = [.init(id: "retained", netID: "N", segments: [.init(id: "wire", layer: 2, x1: 1500, y1: y, x2: 7500, y2: y, widthDBU: 100)])]
        snapshot.implementationState = .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 25),
            .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 25)])
        try geometry.validate(snapshot)
        let design = try await store.registerInput(Data("module fixture_top(); wire N; INV_X1 U1(.Y(N)); INV_X1 U2(.A(N)); endmodule\n".utf8), relativePath: "inputs/eco.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Native geometry admission only.\n".utf8), relativePath: "inputs/eco.sdc", kind: .constraint, format: .sdc)
        request = PhysicalDesignRequest(runID: request.runID, inputBindings: base.inputBindings.filter { $0.reference == base.pdk.manifest } + [design, constraints],
            design: .init(artifact: design.reference, topDesignName: base.design.topDesignName, designDigest: design.reference.digest.hexadecimalValue), constraints: constraints,
            requestedModeIDs: base.requestedModeIDs, pdk: base.pdk, stage: request.stage, configuration: request.configuration, initialSnapshot: snapshot, processAssets: base.processAssets)
        return .init(geometry: geometry, request: request, store: store)
    }
    private struct Fixture {
        let geometry: PhysicalDesignProcessGeometry
        var request: PhysicalDesignRequest
        let store: InMemoryPhysicalDesignArtifactStore
    }
}
