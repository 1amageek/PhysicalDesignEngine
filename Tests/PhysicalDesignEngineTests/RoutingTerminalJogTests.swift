import Foundation
import LayoutIR
import MaskGeometry
import PDKCore
import Testing
@testable import PhysicalDesignCore

@Suite("Source-bound terminal adjacent-track jogs", .timeLimit(.minutes(1)))
struct RoutingTerminalJogTests {
    @Test func blockedPreferredEscapesUseLegalTerminalJogAndResume() async throws {
        let (input, configuration, geometry) = try await fixture()
        do {
            _ = try PhysicalDesignSourceRouter().route(input, configuration: configuration,
                mode: "detailed", onlyNetID: "N", geometry: geometry, bypassingLayers: [], terminalTrackJogs: false)
            Issue.record("The preferred-only generation profile unexpectedly granted a terminal jog.")
        } catch let error as PhysicalDesignSourceRouter.Failure {
            #expect(error.code == "routing_path_unavailable")
        }
        // The two nearest preferred-row contacts are illegal under the actual source predicates.
        let prior = try #require(input.vias.first)
        let lower = PhysicalDesignSnapshot.Via(id: "lower", netID: "N", x: 500, y: 900,
            lowerLayer: 2, upperLayer: 3, master: "hv")
        #expect(try !geometry.routingCutsFit(lower, against: [prior]))
        let upperShapes = try geometry.viaShapes(master: "hv", x: 500, y: 1100)
        let upper = Region(layer: 3, polygons: upperShapes.filter { $0.layer == 3 })
        let obstacle = try PhysicalDesignRoutingSpacingGeometry.compile(
            PhysicalDesignSourceRouter.rectangle(.init(x: 450, y: 1250, width: 100, height: 100), layer: 3))
        let rule = try #require(geometry.routingSpacingRules[3])
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(upper, from: obstacle, rule: rule, minimum: 100))
        let witness = PhysicalDesignSnapshot.RouteSegment(id: "witness", layer: 3,
            x1: 500, y1: 1000, x2: 900, y2: 1000, widthDBU: 100,
            endpointExtensions: .init(beginDBU: 50, endDBU: 50))
        let jog = try PhysicalDesignSourceRouter.conductor(witness, width: 100)
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(jog, from: obstacle, rule: rule, minimum: 100))
        var neighbor = lower; neighbor.x = 900
        #expect(try geometry.routingCutsFit(neighbor, against: [prior]))
        let neighborShapes = try geometry.viaShapes(master: "hv", x: 900, y: 900)
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(
            Region(layer: 3, polygons: neighborShapes.filter { $0.layer == 3 }),
            from: obstacle, rule: rule, minimum: 100))
        let output = try PhysicalDesignSourceRouter().route(input, configuration: configuration,
            mode: "detailed", onlyNetID: "N", geometry: geometry).snapshot
        let route = try #require(output.routes.first { $0.netID == "N" })
        #expect(route.segments.contains { $0.layer == 3 && $0.y1 == 1000 && $0.y2 == 1000 && $0.x1 != $0.x2 })
        #expect(output.routes.filter { $0.netID == "CLK" } == input.routes)
        #expect(output.vias.filter { $0.netID == "CLK" } == input.vias)
        try geometry.validateRoutingCuts(output.vias)
        try geometry.validate(output)
        let codec = PhysicalDesignJSONCodec()
        let reread = try codec.decode(PhysicalDesignSnapshot.self, from: codec.encode(output))
        #expect(reread == output)
        // Another net selection keeps N's actual offpreferred conductor rather than rejecting it.
        var resumed = reread
        resumed.nets.append(.init(id: "UNROUTED", pinIDs: ["R0", "R1"]))
        for (id, x) in [("R0", Int64(100)), ("R1", Int64(1700))] {
            resumed.pins.append(Self.pin(id, net: "UNROUTED", layer: 2, x: x, y: 1900, half: 50))
        }
        try geometry.validate(resumed)
        let retained = try PhysicalDesignSourceRouter().route(resumed, configuration: configuration,
            mode: "detailed", onlyNetID: "UNROUTED", geometry: geometry).snapshot
        #expect(retained.routes.filter { $0.netID == "N" } == output.routes.filter { $0.netID == "N" })
        #expect(retained.vias.filter { $0.netID == "N" } == output.vias.filter { $0.netID == "N" })
    }

    @Test func terminalEdgesHaveExplicitFiniteAdmission() throws {
        var ordinaryBudget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var ordinary = try PhysicalDesignRoutingEventGraph(xCount: 2, yCount: 1, layers: [2],
            defaultMasterCount: 0, budget: &ordinaryBudget)
        let a = PhysicalDesignRoutingSearch.Node(x: 0, y: 0, layer: 2)
        let b = PhysicalDesignRoutingSearch.Node(x: 1, y: 0, layer: 2)
        try ordinary.addUndirected(from: a, to: b, contact: nil, budget: &ordinaryBudget)
        try ordinary.addUndirected(from: a, to: b, contact: nil, budget: &ordinaryBudget)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try ordinary.addUndirected(from: a, to: b, contact: nil, budget: &ordinaryBudget)
        }
        var extendedBudget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var extended = try PhysicalDesignRoutingEventGraph(xCount: 2, yCount: 1, layers: [2],
            defaultMasterCount: 0, terminalAccessCount: 1, budget: &extendedBudget)
        for _ in 0..<4 { try extended.addUndirected(from: a, to: b, contact: nil, budget: &extendedBudget) }
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try extended.addUndirected(from: a, to: b, contact: nil, budget: &extendedBudget)
        }
        var limited = PhysicalDesignRoutingWorkBudget(caller: 1)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            _ = try PhysicalDesignRoutingEventGraph(xCount: 2, yCount: 1, layers: [2],
                defaultMasterCount: 0, terminalAccessCount: 1, budget: &limited)
        }
        var overflow = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            _ = try PhysicalDesignRoutingEventGraph(xCount: 2, yCount: 1, layers: [2],
                defaultMasterCount: 0, terminalAccessCount: Int.max, budget: &overflow)
        }
    }

    @Test func sparseEventsDoNotSkipTheMissingDeclaredNeighbor() throws {
        let track = PhysicalDesignImplementationState.Track(id: "V", layer: 3, direction: "vertical",
            origin: 100, spacing: 400, count: 6)
        let sparseEvents: [Int64] = [100, 500, 1300, 1700]
        #expect(!sparseEvents.contains(900))
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try !PhysicalDesignSourceRouter.adjacentDeclaredTracks(sparseEvents[1], sparseEvents[2],
            layer: 3, tracks: [track], budget: &budget))
        #expect(try !PhysicalDesignSourceRouter.adjacentDeclaredTracks(sparseEvents[2], sparseEvents[1],
            layer: 3, tracks: [track], budget: &budget))
        #expect(try PhysicalDesignSourceRouter.adjacentDeclaredTracks(500, 900, layer: 3, tracks: [track], budget: &budget))
        #expect(try PhysicalDesignSourceRouter.adjacentDeclaredTracks(500, 100, layer: 3, tracks: [track], budget: &budget))
        #expect(try !PhysicalDesignSourceRouter.adjacentDeclaredTracks(2100, 2500, layer: 3, tracks: [track], budget: &budget))
        #expect(try !PhysicalDesignSourceRouter.adjacentDeclaredTracks(500, 900, layer: 2, tracks: [track], budget: &budget))
    }

    @Test func terminalRoutingUsesCallerQuotaAndCancellation() async throws {
        let (input, original, geometry) = try await fixture()
        var limited = original; limited.maximumRoutingCandidateChecks = 1
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            _ = try PhysicalDesignSourceRouter().route(input, configuration: limited,
                mode: "detailed", onlyNetID: "N", geometry: geometry)
        }
        let task = Task {
            try Task.checkCancellation()
            return try PhysicalDesignSourceRouter().route(input, configuration: original,
                mode: "detailed", onlyNetID: "N", geometry: geometry)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled routing completed.") }
        catch is CancellationError {}
    }

    private static func pin(_ id: String, net: String, layer: Int, x: Int64, y: Int64, half: Int64) -> PhysicalDesignSnapshot.Pin {
        .init(id: id, cellID: nil, name: id, x: x, y: y, netID: net, direction: "input", accessLayer: layer,
            topPort: .init(rectangle: .init(x: -half, y: -half, width: half * 2, height: half * 2),
                layer: layer, placementX: x, placementY: y, orientation: .n, placementStatus: .fixed, use: .signal))
    }

    private func fixture() async throws -> (PhysicalDesignSnapshot, PhysicalDesignConfiguration, PhysicalDesignProcessGeometry) {
        var (request, store) = try await ProcessGeometryTests().fixtureSources()
        let original = try #require(request.processAssets["tech"])
        let source = try #require(String(data: await store.read(original), encoding: .utf8))
            .replacingOccurrences(of: "TYPE CUT ; WIDTH 0.05 ; SPACING 0.05 ;", with: "TYPE CUT ; WIDTH 0.05 ; SPACING 0.19 ;")
        let bytes = Data(source.utf8)
        let technology = try await store.registerInput(bytes, relativePath: "inputs/jog-tech.lef", kind: .technology, format: .lef)
        var manifest = try PDKManifestCodec.decode(data: await store.read(request.requireBinding(for: request.pdk.manifest)))
        let index = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[index].path = technology.path
        manifest.assets[index].sha256 = technology.reference.digest.hexadecimalValue
        manifest.assets[index].byteCount = Int64(bytes.count)
        let binding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/jog-process.json", kind: .technology, format: .json)
        let previous = request.pdk.manifest
        request.inputBindings.removeAll { $0.reference == previous || $0 == original }
        request.pdk = try .init(manifest: binding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: binding),
            processID: request.pdk.processID, version: request.pdk.version)
        request.processAssets["tech"] = technology
        request.inputBindings.append(contentsOf: [binding, technology])
        request.inputs = request.inputBindings.map(\.reference)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        var configuration = ProcessGeometryTests().nativeRequest(request).configuration
        configuration.maximumRoutingLayer = 3
        let snapshot = PhysicalDesignSnapshot(topCell: request.design.topDesignName, unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 2200, height: 2200), core: .init(x: 0, y: 0, width: 2200, height: 2200),
            pins: [Self.pin("A", net: "N", layer: 3, x: 500, y: 1000, half: 50),
                Self.pin("B", net: "N", layer: 2, x: 1700, y: 900, half: 50),
                Self.pin("C0", net: "CLK", layer: 2, x: 100, y: 700, half: 50),
                Self.pin("C1", net: "CLK", layer: 3, x: 500, y: 700, half: 100),
                Self.pin("C2", net: "CLK", layer: 3, x: 500, y: 1300, half: 50)],
            nets: [.init(id: "N", pinIDs: ["A", "B"]), .init(id: "CLK", pinIDs: ["C0", "C1", "C2"], isClock: true)],
            clockTrees: [.init(id: "retained-clock", netID: "CLK", sourcePinID: "C0", sinkPinIDs: ["C1", "C2"])],
            routes: [.init(id: "retained", netID: "CLK", segments: [.init(id: "clock", layer: 2,
                x1: 100, y1: 700, x2: 500, y2: 700, widthDBU: 100,
                endpointExtensions: .init(beginDBU: 50, endDBU: 50))], defStatus: .routed)],
            vias: [.init(id: "retained-via", netID: "CLK", x: 500, y: 700, lowerLayer: 2, upperLayer: 3, master: "hv")],
            implementationState: .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 11),
                .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 6)]))
        let bound = try geometry.bind(snapshot)
        try geometry.validate(bound)
        return (bound, configuration, geometry)
    }
}
