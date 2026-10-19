import Foundation
import LayoutIR
import MaskGeometry
import PDKCore
import Testing
@testable import PhysicalDesignCore

@Suite("Source-bound terminal access reservations", .timeLimit(.minutes(1)))
struct RoutingAccessReservationTests {
    @Test("contact-required priority follows source access, independently of declaration spelling", arguments: [false, true])
    func sourceAccessPrioritySurvivesRenaming(_ reverseNames: Bool) async throws {
        let fixture = try await fixture()
        var snapshot = fixture.snapshot
        let directID = reverseNames ? "z_data_D" : "a_clock_Q"
        let contactID = reverseNames ? "a_clock_Q" : "z_data_D"
        for index in snapshot.nets.indices {
            if snapshot.nets[index].id == "A" { snapshot.nets[index].id = directID }
            else if snapshot.nets[index].id == "B" { snapshot.nets[index].id = contactID }
        }
        for index in snapshot.pins.indices {
            if snapshot.pins[index].netID == "A" { snapshot.pins[index].netID = directID }
            else if snapshot.pins[index].netID == "B" { snapshot.pins[index].netID = contactID }
        }
        try fixture.geometry.validate(snapshot)
        let output = try PhysicalDesignSourceRouter().route(snapshot, configuration: fixture.configuration,
            mode: "detailed", onlyNetID: nil, geometry: fixture.geometry).snapshot
        let generated = output.routes.filter { $0.netID != "CLK" }
        #expect(generated.map { $0.netID } == [contactID, directID])
        #expect(output.vias.contains { $0.netID == contactID && $0.x == 1000 && $0.y == 700 })
        #expect(output.clockTrees == snapshot.clockTrees)
        #expect(output.routes.filter { $0.netID == "CLK" } == snapshot.routes.filter { $0.netID == "CLK" })
        try fixture.geometry.validate(output)
    }

    @Test("split landing RECTs reserve their actual same-layer union width")
    func splitLandingUnionPreservesLaterAccess() async throws {
        let fixture = try await fixture(splitLanding: true)
        let shapes = try fixture.geometry.viaShapes(master: "hv", x: 1000, y: 700)
        let metal = shapes.filter { $0.layer == 2 }
        try #require(metal.count == 2)
        let rule = try #require(fixture.geometry.routingSpacingRules[2])
        let shortcut = PhysicalDesignSnapshot.RouteSegment(id: "old-shortcut", layer: 2,
            x1: 300, y1: 1000, x2: 1900, y2: 1000, widthDBU: 100,
            endpointExtensions: .init(beginDBU: 50, endDBU: 50))
        let conductor = try PhysicalDesignSourceRouter.conductor(shortcut, width: 100)
        for shape in metal {
            let part = try PhysicalDesignRoutingSpacingGeometry.compile(Region(layer: 2, polygons: [shape]))
            #expect(part.rectangles.allSatisfy { $0.width == 100 })
            #expect(try PhysicalDesignRoutingSpacingGeometry.separated(conductor, from: part, rule: rule, minimum: 100))
        }
        let union = try PhysicalDesignRoutingSpacingGeometry.compile(Region(layer: 2, polygons: metal))
        #expect(union.rectangles.count == 1 && union.rectangles[0].width == 200)
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(conductor, from: union, rule: rule, minimum: 100))
        // The production router must reserve the union, then detour before routing B.
        let output = try PhysicalDesignSourceRouter().route(fixture.snapshot, configuration: fixture.configuration,
            mode: "detailed", onlyNetID: nil, geometry: fixture.geometry).snapshot
        #expect(output.routes.filter { $0.netID == "A" || $0.netID == "B" }.count == 2)
        // Both roots require contacts, so stable-ID order keeps the reservation regression active.
        #expect(output.routes.filter { $0.netID != "CLK" }.map { $0.netID } == ["A", "B"])
        #expect(output.vias.contains { $0.netID == "A" && $0.x == 300 && $0.y == 1000 })
        #expect(output.vias.contains { $0.netID == "B" && $0.x == 1000 && $0.y == 700 })
        for route in output.routes where route.netID == "A" {
            for segment in route.segments where segment.layer == 2 {
                #expect(try PhysicalDesignRoutingSpacingGeometry.separated(
                    PhysicalDesignSourceRouter.conductor(segment, width: try #require(segment.widthDBU)),
                    from: union, rule: rule, minimum: 100))
            }
        }
        try fixture.geometry.validateRoutingCuts(output.vias)
        try fixture.geometry.validate(output)
    }

    @Test("an earlier wire detours around a later off-track PORT's exact contact access")
    func laterContactRemainsReachable() async throws {
        let fixture = try await fixture()
        let result = try PhysicalDesignSourceRouter().route(fixture.snapshot,
            configuration: fixture.configuration, mode: "detailed", onlyNetID: nil, geometry: fixture.geometry)
        let output = result.snapshot
        #expect(output.routes.filter { $0.netID == "A" }.count == 1)
        #expect(output.routes.filter { $0.netID == "B" }.count == 1)
        let access = try #require(output.vias.first { $0.netID == "B" && $0.x == 1000 && $0.y == 700 })
        #expect(access.master == "hv")
        let shapes = try fixture.geometry.viaShapes(master: "hv", x: access.x, y: access.y)
        let landing = Region(layer: 2, polygons: shapes.filter { $0.layer == 2 })
        // The old straight wire crosses this landing although the source PORT is on layer 3.
        let shortcut = PhysicalDesignSnapshot.RouteSegment(id: "old-shortcut", layer: 2,
            x1: 100, y1: 700, x2: 1900, y2: 700, widthDBU: 100,
            endpointExtensions: .init(beginDBU: 50, endDBU: 50))
        #expect(try !PhysicalDesignSourceRouter.conductor(shortcut, width: 100).intersection(landing).isEmpty)
        let route = try #require(output.routes.first { $0.netID == "A" })
        for segment in route.segments where segment.layer == 2 {
            let actual = try PhysicalDesignSourceRouter.conductor(segment, width: try #require(segment.widthDBU))
            #expect(try actual.intersection(landing).isEmpty)
            #expect(try actual.spaceViolations(to: landing, minSpace: 100).isEmpty)
        }
        #expect(output.routes.filter { $0.netID == "CLK" } == fixture.snapshot.routes.filter { $0.netID == "CLK" })
        #expect(output.clockTrees == fixture.snapshot.clockTrees)
        #expect(output.routes.allSatisfy { $0.id.hasPrefix("route_") || $0.id == "clock-retained" })
        #expect(output.vias.allSatisfy { $0.id.hasPrefix("route_") })
        try fixture.geometry.validateRoutingCuts(output.vias)
        try fixture.geometry.validate(output)
        #expect(result.checks > 0 && result.checks <= result.structuralCeiling)
    }

    @Test("conflicting foreign source terminals never receive an unreserved fallback")
    func conflictingOwnersRefused() async throws {
        let fixture = try await fixture()
        var snapshot = fixture.snapshot
        let index = try #require(snapshot.pins.firstIndex { $0.id == "B0" })
        snapshot.pins[index].x = 100
        snapshot.pins[index].accessLayer = 2
        snapshot.pins[index].topPort = .init(rectangle: .init(x: -100, y: -100, width: 200, height: 200),
            layer: 2, placementX: 100, placementY: 700, orientation: .n, placementStatus: .fixed, use: .signal)
        do {
            _ = try PhysicalDesignSourceRouter().route(snapshot, configuration: fixture.configuration,
                mode: "detailed", onlyNetID: nil, geometry: fixture.geometry)
            Issue.record("Conflicting foreign source terminals received a completed route.")
        } catch let failure as PhysicalDesignSourceRouter.Failure {
            #expect(failure.code == "routing_pin_access_unavailable")
        }
        #expect(snapshot.routes == fixture.snapshot.routes && snapshot.vias.isEmpty)
    }

    @Test("both reservation and search consume the same caller ceiling and cancellation")
    func finiteCallerAndCancellation() async throws {
        let fixture = try await fixture()
        var configuration = fixture.configuration
        configuration.maximumRoutingCandidateChecks = 1
        do {
            _ = try PhysicalDesignSourceRouter().route(fixture.snapshot, configuration: configuration,
                mode: "detailed", onlyNetID: nil, geometry: fixture.geometry)
            Issue.record("Routing exceeded its caller allowance without refusal.")
        } catch let failure as PhysicalDesignSourceRouter.Failure {
            #expect(failure.code == "routing_candidate_budget_exhausted")
        }
        let task = Task {
            try Task.checkCancellation()
            return try PhysicalDesignSourceRouter().route(fixture.snapshot, configuration: fixture.configuration,
                mode: "detailed", onlyNetID: nil, geometry: fixture.geometry)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled routing call returned a completed candidate.")
        } catch is CancellationError {
            // Cancellation remains distinct from source admission failure.
        }
    }

    private func fixture(splitLanding: Bool = false) async throws -> (snapshot: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration, geometry: PhysicalDesignProcessGeometry) {
        var (base, store) = try await ProcessGeometryTests().fixtureSources()
        if splitLanding {
            let oldTech = try #require(base.processAssets["tech"])
            let text = try #require(String(data: await store.read(oldTech), encoding: .utf8))
                .replacingOccurrences(of: "PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ;", with:
                    "PITCH 0.1 ; OFFSET 0 ; WIDTH 0.1 ; SPACINGTABLE PARALLELRUNLENGTH 0 WIDTH 0 0.1 WIDTH 0.15 0.2 ;")
                .replacingOccurrences(of: "LAYER metH ; RECT -0.1 -0.1 0.1 0.1 ;", with:
                    "LAYER metH ; RECT -0.2 -0.1 0.2 0 ; RECT -0.2 0 0.2 0.1 ;")
            let tech = try await store.registerInput(Data(text.utf8), relativePath: "inputs/reservation-union.lef", kind: .technology, format: .lef)
            var manifest = try PDKManifestCodec.decode(data: await store.read(base.requireBinding(for: base.pdk.manifest)))
            let asset = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
            manifest.assets[asset].path = "reservation-union.lef"
            manifest.assets[asset].sha256 = tech.reference.digest.hexadecimalValue
            manifest.assets[asset].byteCount = Int64(tech.reference.byteCount)
            let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/reservation-union.json", kind: .technology, format: .json)
            let bindings = base.inputBindings.filter { $0.reference != base.pdk.manifest && $0.reference != oldTech.reference } + [pdk]
            var assets = base.processAssets
            assets["tech"] = tech
            // The initializer owns both prerequisite inventories; mutating bindings alone leaves stale inputs.
            base = PhysicalDesignRequest(runID: base.runID, inputBindings: bindings, design: base.design,
                constraints: base.constraints, requestedModeIDs: base.requestedModeIDs,
                pdk: try .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk),
                    processID: base.pdk.processID, version: base.pdk.version),
                stage: base.stage, configuration: base.configuration, executionIntent: base.executionIntent, processAssets: assets)
        }
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: base, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: base, units: 1000)
        var configuration = ProcessGeometryTests().nativeRequest(base).configuration
        configuration.maximumRoutingLayer = 3
        func pin(_ id: String, net: String, layer: Int, x: Int64, y: Int64, half: Int64) -> PhysicalDesignSnapshot.Pin {
            .init(id: id, cellID: nil, name: id, x: x, y: y, netID: net,
                direction: id.hasSuffix("0") ? "input" : "output", accessLayer: layer,
                topPort: .init(rectangle: .init(x: -half, y: -half, width: 2 * half, height: 2 * half),
                    layer: layer, placementX: x, placementY: y, orientation: .n, placementStatus: .fixed, use: .signal))
        }
        let snapshot = PhysicalDesignSnapshot(topCell: base.design.topDesignName, unitsPerMicron: 1000,
            die: .init(x: splitLanding ? -200 : 0, y: 0, width: splitLanding ? 2600 : 2200, height: 2200),
            core: .init(x: splitLanding ? -200 : 0, y: 0, width: splitLanding ? 2600 : 2200, height: 2200),
            pins: [pin("A0", net: "A", layer: splitLanding ? 3 : 2, x: splitLanding ? 300 : 100,
                y: splitLanding ? 1000 : 700, half: splitLanding ? 100 : 50),
                pin("A1", net: "A", layer: 2, x: 1900, y: splitLanding ? 1000 : 700, half: 50),
                pin("B0", net: "B", layer: 3, x: 1000, y: 700, half: 100),
                pin("B1", net: "B", layer: 3, x: 1700, y: 1500, half: 50),
                pin("C0", net: "CLK", layer: 2, x: 100, y: 1900, half: 50),
                pin("C1", net: "CLK", layer: 2, x: 1900, y: 1900, half: 50)],
            nets: [.init(id: "A", pinIDs: ["A0", "A1"]), .init(id: "B", pinIDs: ["B0", "B1"]),
                .init(id: "CLK", pinIDs: ["C0", "C1"], isClock: true)],
            clockTrees: [.init(id: "clock", netID: "CLK", sourcePinID: "C0", sinkPinIDs: ["C1"])],
            routes: [.init(id: "clock-retained", netID: "CLK", segments: [.init(id: "clock-wire", layer: 2,
                x1: 100, y1: 1900, x2: 1900, y2: 1900, widthDBU: 100,
                endpointExtensions: .init(beginDBU: 50, endDBU: 50))], defStatus: .routed)],
            implementationState: .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: splitLanding ? 0 : 100, spacing: splitLanding ? 100 : 200, count: splitLanding ? 23 : 11),
                .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 6)]))
        let bound = try geometry.bind(snapshot)
        try geometry.validate(bound)
        return (bound, configuration, geometry)
    }
}
