import Foundation
import LayoutIR
import MaskGeometry
import PDKCore
import Testing
@testable import PhysicalDesignCore

@Suite("Source routing with persistent contact histories", .timeLimit(.minutes(1)))
struct RoutingContactSearchTests {
    @Test("an illegal two-contact shortcut leaves the legal four-contact history searchable")
    func legalHistoryDetour() async throws {
        let fixture = try await fixture(terminalAccess: false)
        let result = try PhysicalDesignSourceRouter().route(fixture.snapshot, configuration: fixture.request.configuration,
            mode: "global", onlyNetID: "N", geometry: fixture.geometry)
        let output = result.snapshot
        #expect(output.vias.count >= 4)
        #expect(output.vias.allSatisfy { $0.master == "hv" })
        try fixture.geometry.validateRoutingCuts(output.vias)
        try fixture.geometry.validate(output)
        // The source law rejects the old shortest two-contact path, independently of search.
        let first = PhysicalDesignSnapshot.Via(id: "shortcut-start", netID: "N", x: 300, y: 1000,
            lowerLayer: 2, upperLayer: 3, master: "hv")
        var second = first; second.id = "shortcut-end"; second.y += 600
        #expect(throws: PhysicalDesignTechnologyError.self) { try fixture.geometry.validateRoutingCuts([first, second]) }
        let codec = PhysicalDesignJSONCodec()
        #expect(try codec.decode(PhysicalDesignSnapshot.self, from: codec.encode(output)) == output)
        #expect(result.checks > 0 && result.checks <= result.structuralCeiling)
    }

    @Test("the target's specific DEFAULT access is checked before accepting its node")
    func alternateTerminalMaster() async throws {
        let fixture = try await fixture(terminalAccess: true)
        let port = try PhysicalDesignSourceRouter.rectangle(.init(x: 1400, y: 1160, width: 200, height: 200), layer: 2)
        for master in ["hv", "z_small"] {
            for delta: Int64 in [-5, 0, 5] {
                let shapes = try fixture.geometry.viaShapes(master: master, x: 1500, y: 1260 + delta)
                let metal = Region(layer: 2, polygons: shapes.filter { $0.layer == 2 })
                #expect(try metal.subtracting(port).isEmpty == (delta == 0))
            }
        }
        let output = try PhysicalDesignSourceRouter().route(fixture.snapshot, configuration: fixture.request.configuration,
            mode: "global", onlyNetID: "N", geometry: fixture.geometry).snapshot
        // Large/large and large/small at 260 DBU both fail; small/small is legal.
        #expect(output.vias.count == 2)
        #expect(output.vias.allSatisfy { $0.master == "z_small" }, "\(output.vias)")
        let terminal = try #require(output.pins.first { $0.id == "B" })
        #expect(terminal.accessLayer == 2 && terminal.y == 1260, "\(terminal); \(output.vias)")
        #expect(output.vias.contains { $0.x == terminal.x && $0.y == terminal.y && $0.master == "z_small" })
        try fixture.geometry.validateRoutingCuts(output.vias)
        try fixture.geometry.validate(output)
    }

    @Test("an overlapping target access retains a nonempty path from another root access")
    func seedCannotHideProgressedTarget() async throws {
        let fixture = try await fixture(terminalAccess: false, blockingTerminalJogs: false)
        var input = fixture.snapshot
        input.pins[0].topPort = .init(rectangle: .init(x: -150, y: -50, width: 300, height: 100), layer: 2,
            placementX: 300, placementY: 1000, orientation: .n, placementStatus: .fixed, use: .signal)
        input.pins[1].x = 400; input.pins[1].y = 1000
        input.pins[1].topPort = .init(rectangle: .init(x: -50, y: -50, width: 100, height: 100), layer: 2,
            placementX: 400, placementY: 1000, orientation: .n, placementStatus: .fixed, use: .signal)
        let output = try PhysicalDesignSourceRouter().route(input, configuration: fixture.request.configuration,
            mode: "global", onlyNetID: nil, geometry: fixture.geometry).snapshot
        #expect(output.vias.isEmpty)
        #expect(!output.routes.flatMap(\.segments).isEmpty)
        let root = try #require(output.pins.first { $0.id == "A" })
        let target = try #require(output.pins.first { $0.id == "B" })
        #expect(root.x != target.x && root.y == target.y && target.x == 400)
        try fixture.geometry.validate(output)
    }

    @Test("goal-directed heap orders g+h, then h, then stable labels under one caller allowance")
    func goalDirectedHeap() throws {
        func ordered(caller: Int?) throws -> (order: [Int], checks: Int) {
            var budget = PhysicalDesignRoutingWorkBudget(caller: caller)
            var search = PhysicalDesignRoutingSearch(maximumLabels: 5)
            let node = PhysicalDesignRoutingSearch.Node(x: 0, y: 0, layer: 2)
            try search.append(node: node, rootAccess: 0, history: 0, previous: nil, contact: nil, budget: &budget)
            #expect(try search.next(budget: &budget) == 0)
            try search.append(node: node, rootAccess: 0, history: 1, previous: 0, contact: 0, remaining: 9, budget: &budget)
            try search.append(node: node, rootAccess: 0, history: 2, previous: 0, contact: 1, remaining: 1, budget: &budget)
            try search.append(node: node, rootAccess: 0, history: 3, previous: 0, contact: 2, remaining: 1, budget: &budget)
            try search.append(node: node, rootAccess: 0, history: 4, previous: 2, contact: 3, remaining: 0, budget: &budget)
            var order: [Int] = []
            while let index = try search.next(budget: &budget) { order.append(index) }
            return (order, budget.checks)
        }
        let measured = try ordered(caller: nil)
        #expect(measured.order == [4, 2, 3, 1])
        let exact = try ordered(caller: measured.checks)
        #expect(exact.order == measured.order && exact.checks == measured.checks)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) { try ordered(caller: measured.checks - 1) }
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var search = PhysicalDesignRoutingSearch(maximumLabels: 2)
        let node = PhysicalDesignRoutingSearch.Node(x: 0, y: 0, layer: 2)
        try search.append(node: node, rootAccess: 0, history: 0, previous: nil, contact: nil, budget: &budget)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try search.append(node: node, rootAccess: 0, history: 1, previous: 0, contact: 0, remaining: Int.max, budget: &budget)
        }
        #expect(search.labels.count == 1)
    }

    private func fixture(terminalAccess: Bool, blockingTerminalJogs: Bool = true) async throws -> (
        request: PhysicalDesignRequest, snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry
    ) {
        let (base, store) = try await ProcessGeometryTests().fixtureSources()
        let oldTech = try #require(base.processAssets["tech"])
        let bytes = try await store.read(oldTech)
        var text = try #require(String(data: bytes, encoding: .utf8))
        text = text.replacingOccurrences(of: "PITCH 0.2 ; OFFSET 0.1", with: "PITCH 0.34 ; OFFSET 0.32")
            .replacingOccurrences(of: "PITCH 0.4 ; OFFSET 0.1", with: "PITCH 0.6 ; OFFSET 0.3")
            .replacingOccurrences(of: "WIDTH 0.05 ; SPACING 0.05", with: "WIDTH 0.02 ; SPACING 0.19")
            .replacingOccurrences(of: "RECT -0.025 -0.025 0.025 0.025", with: "RECT -0.085 -0.085 0.085 0.085")
        if terminalAccess {
            let begin = try #require(text.range(of: "VIA hv DEFAULT"))
            let end = try #require(text.range(of: "END hv"))
            let small = String(text[begin.lowerBound..<end.upperBound])
                .replacingOccurrences(of: "hv", with: "z_small")
                .replacingOccurrences(of: "RECT -0.085 -0.085 0.085 0.085", with: "RECT -0.01 -0.01 0.01 0.01")
            text = text.replacingOccurrences(of: "END LIBRARY", with: small + "\nEND LIBRARY")
        } else if blockingTerminalJogs {
            text = text.replacingOccurrences(of: "PITCH 0.34 ; OFFSET 0.32", with: "PITCH 0.6 ; OFFSET 0.4")
                .replacingOccurrences(of: "PITCH 0.6 ; OFFSET 0.3", with: "PITCH 0.8 ; OFFSET 0.3")
                .replacingOccurrences(of: "WIDTH 0.02 ; SPACING 0.19", with: "WIDTH 0.02 ; SPACING 0.5")
        }
        let tech = try await store.registerInput(Data(text.utf8), relativePath: "inputs/contact-history.lef", kind: .technology, format: .lef)
        let manifestBytes = try await store.read(base.requireBinding(for: base.pdk.manifest))
        var manifest = try PDKManifestCodec.decode(data: manifestBytes)
        let asset = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[asset].path = "contact-history.lef"
        manifest.assets[asset].sha256 = tech.reference.digest.hexadecimalValue
        manifest.assets[asset].byteCount = Int64(tech.reference.byteCount)
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/contact-history.json", kind: .technology, format: .json)
        let design = try await store.registerInput(Data("module fixture_top(input A, output B); assign B = A; endmodule\n".utf8),
            relativePath: "inputs/contact-history.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Synthetic source routing geometry regression.\n".utf8),
            relativePath: "inputs/contact-history.sdc", kind: .constraint, format: .sdc)
        let targetY: Int64 = terminalAccess ? 1260 : (blockingTerminalJogs ? 1600 : 1340)
        func terminal(_ id: String, x: Int64, y: Int64, half: Int64) -> PhysicalDesignSnapshot.Pin {
            .init(id: id, cellID: nil, name: id, x: x, y: y, netID: "N", direction: id == "A" ? "input" : "output", accessLayer: 2,
                topPort: .init(rectangle: .init(x: -half, y: -half, width: 2 * half, height: 2 * half), layer: 2,
                    placementX: x, placementY: y, orientation: .n, placementStatus: .fixed, use: .signal))
        }
        var snapshot = PhysicalDesignSnapshot(topCell: "fixture_top", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 2400, height: 3200), core: .init(x: 0, y: 0, width: 2400, height: 3200),
            pins: [terminal("A", x: 300, y: 1000, half: 50), terminal("B", x: 1500, y: targetY, half: terminalAccess ? 100 : 50)],
            nets: [.init(id: "N", pinIDs: ["A", "B"])],
            implementationState: .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 320, spacing: 340, count: 5),
                .init(id: "V", layer: 3, direction: "vertical", origin: 300, spacing: 600, count: 3)]))
        if blockingTerminalJogs {
            // Foreign source PORTs block only the newly legal terminal jogs, preserving the contact-history proof.
            let obstacles: [(Int, Int64, Int64, Int64)] = terminalAccess
                ? [(2, 300, 780, 20), (2, 300, 1220, 20), (3, 1200, 1260, 20), (3, 1800, 1260, 20)]
                : [(2, 300, 700, 50), (2, 300, 1300, 50), (2, 1500, 1300, 50), (2, 1500, 1900, 50)]
            let obstacleIDs = obstacles.indices.map { "fixed-obstacle-\($0)" }
            for (index, obstacle) in obstacles.enumerated() {
                let (layer, x, y, half) = obstacle
                snapshot.pins.append(.init(id: obstacleIDs[index], cellID: nil, name: obstacleIDs[index],
                    x: x, y: y, netID: "FOREIGN", direction: "input", accessLayer: layer,
                    topPort: .init(rectangle: .init(x: -half, y: -half, width: half * 2, height: half * 2),
                        layer: layer, placementX: x, placementY: y, orientation: .n, placementStatus: .fixed, use: .signal)))
            }
            snapshot.nets.append(.init(id: "FOREIGN", pinIDs: obstacleIDs))
            if !terminalAccess {
                snapshot.implementationState?.tracks = [
                    .init(id: "H", layer: 2, direction: "horizontal", origin: 400, spacing: 600, count: 5),
                    .init(id: "V", layer: 3, direction: "vertical", origin: 300, spacing: 800, count: 3)]
            }
        }
        let configuration = ProcessGeometryTests().nativeRequest(base).configuration
        let request = PhysicalDesignRequest(runID: "contact-history", inputBindings: [pdk, design, constraints],
            design: .init(artifact: design.reference, topDesignName: "fixture_top", designDigest: design.reference.digest.hexadecimalValue),
            constraints: constraints, requestedModeIDs: base.requestedModeIDs,
            pdk: try .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk), processID: base.pdk.processID, version: base.pdk.version),
            stage: .globalRouting, configuration: configuration, initialSnapshot: snapshot,
            processAssets: ["tech": tech, "cells": try #require(base.processAssets["cells"])])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        return (request, try geometry.bind(snapshot), geometry)
    }
}
