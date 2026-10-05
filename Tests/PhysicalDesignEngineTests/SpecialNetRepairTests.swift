import DEF
import Foundation
import PDKCore
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Source-qualified finite special-net repair", .timeLimit(.minutes(1)))
struct SpecialNetRepairTests {
    @Test("four original SPECIALNETS survive cell movement and explicit-width native rerouting")
    func actualFourSpecialNetRepair() async throws {
        var (request, store, geometry) = try await fixture()
        let original = try #require(request.initialSnapshot)
        let originalBytes = try PhysicalDesignJSONCodec().encode(original)
        #expect(original.nets.count == 4 && original.nets.allSatisfy { $0.routingClass == .special && $0.defUse == nil })
        #expect(original.routes.count == 4 && original.routes.allSatisfy {
            $0.defStatus == .routed && $0.defShape == nil && $0.segments.count == 1
                && $0.segments[0].widthDBU == 200 && $0.segments[0].endpointExtensions == .init(beginDBU: 0, endDBU: 0)
        })
        let engine = PhysicalDesignEngine(artifactStore: store)
        let movedResult = try await engine.execute(request)
        #expect(movedResult.status == .completed, "\(movedResult.diagnostics)")
        let movedBinding = try #require(movedResult.payload.physicalDesign?.layoutArtifact)
        let moved = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(movedBinding))
        #expect(moved.cells[0].id == "U1" && moved.cells[0].master == "INV" && moved.cells[0].x == 10200)
        #expect(moved.nets == original.nets && moved.routes.isEmpty && moved.vias.isEmpty)
        #expect(moved.metadata["routingStatus"] == "requires_routing")
        #expect(moved.implementationState?.repairProofs.allSatisfy { !$0.verified } == true)
        #expect(moved.processManifest == original.processManifest && moved.processAssets == original.processAssets)
        #expect(moved.pins.filter { $0.cellID == nil } == original.pins.filter { $0.cellID == nil })
        try geometry.validate(moved)
        request.runID = "special-reroute"; request.stage = .globalRouting
        request.initialSnapshot = moved
        let result = try await engine.execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let binding = try #require(result.payload.physicalDesign?.layoutArtifact)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(binding))
        #expect(output.nets == original.nets && output.cells == moved.cells)
        #expect(output.processManifest == original.processManifest && output.processAssets == original.processAssets)
        #expect(output.pins.filter { $0.cellID == nil }.map(\.topPort) == original.pins.filter { $0.cellID == nil }.map(\.topPort))
        #expect(output.pins.map(\.id) == original.pins.map(\.id) && output.pins.map(\.direction) == original.pins.map(\.direction))
        #expect(output.routes.count == 4 && output.vias.isEmpty)
        #expect(output.routes.allSatisfy { $0.defStatus == .routed && $0.defShape == nil })
        let generatedCaps = PhysicalDesignRouteEndpointExtensions(beginDBU: 100, endDBU: 100)
        for segment in output.routes.flatMap(\.segments) {
            #expect(segment.widthDBU == 200 && segment.layer == 2)
            #expect(segment.endpointExtensions == generatedCaps)
        }
        #expect(output.implementationState?.routingEvidence?.routedNetCount == 4)
        #expect(output.implementationState?.repairProofs.isEmpty == true)
        #expect(result.payload.claims.production == .blocked)
        for pin in output.pins {
            #expect(output.routes.filter { $0.netID == pin.netID }.flatMap(\.segments).contains {
                $0.layer == pin.accessLayer && (($0.x1 == pin.x && $0.y1 == pin.y) || ($0.x2 == pin.x && $0.y2 == pin.y))
            })
        }
        let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        let standard = try DEFLibraryReader.read(await store.read(def))
        #expect(standard.nets.isEmpty && standard.specialNets.count == 4)
        #expect(standard.specialNets.map(\.name).sorted() == ["in", "out", "vdd", "vss"])
        #expect(standard.specialNets.allSatisfy { $0.use == nil && !$0.routing.isEmpty && $0.routing.allSatisfy { $0.width == 200 && $0.status == .routed && $0.shape == nil } })
        #expect(try PhysicalDesignJSONCodec().encode(original) == originalBytes)
        for artifact in result.artifactBindings { _ = try await store.read(artifact) }
    }

    @Test("protected special routing facts cannot disappear through cell invalidation", arguments:
          ["fixed", "cover", "shape", "implicit-width", "missing-width", "different-width", "via", "different-layer"])
    func atomicCellRefusal(scenario: String) async throws {
        var (request, store, _) = try await fixture()
        switch scenario {
        case "fixed": request.initialSnapshot?.routes[0].defStatus = .fixed
        case "cover": request.initialSnapshot?.routes[0].defStatus = .cover
        case "shape": request.initialSnapshot?.routes[0].defShape = .stripe
        case "implicit-width": request.configuration.implementationConstraints = nil
        case "missing-width": request.initialSnapshot?.routes[0].segments[0].widthDBU = nil
        case "different-width": request.configuration.implementationConstraints?.routeWidth = 100
        case "via": request.initialSnapshot?.vias = [.init(id: "source-contact", netID: "in", x: 10300, y: 1500, lowerLayer: 2, upperLayer: 3, master: "hv")]
        default:
            let index = try #require(request.initialSnapshot?.pins.firstIndex { $0.id == "TOP/in" })
            let old = try #require(request.initialSnapshot?.pins[index].topPort)
            request.initialSnapshot?.pins[index].accessLayer = 3
            request.initialSnapshot?.pins[index].topPort = .init(rectangle: old.rectangle, layer: 3, placementX: old.placementX,
                placementY: old.placementY, orientation: old.orientation, placementStatus: old.placementStatus, use: old.use)
        }
        let before = try PhysicalDesignJSONCodec().encode(#require(request.initialSnapshot))
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil, "\(result.diagnostics)")
        let code: String
        switch scenario {
        case "fixed", "cover", "shape": code = "routing_special_route_protected"
        case "implicit-width": code = "routing_special_width_required"
        case "missing-width": code = "physical_technology_invalid"
        case "different-width": code = "routing_special_width_mismatch"
        case "via": code = "routing_special_via_unsupported"
        default: code = "routing_special_layer_unsupported"
        }
        #expect(result.diagnostics.contains { $0.code.rawValue == code }, "\(result.diagnostics)")
        #expect(try PhysicalDesignJSONCodec().encode(#require(request.initialSnapshot)) == before)
        #expect(await store.data(at: "runs/special-move/physical-design/timingECO/revision.json") == nil)
    }

    @Test("special routing rejects protected metadata unavailable paths and caller limits atomically", arguments:
          ["fixed", "cover", "shape", "implicit-width", "missing-width", "different-width", "via", "different-layer", "no-path", "budget"])
    func atomicRoutingRefusal(scenario: String) async throws {
        var (request, store, _) = try await fixture()
        request.stage = .globalRouting; request.runID = "special-rejected-routing"
        switch scenario {
        case "fixed": request.initialSnapshot?.routes[0].defStatus = .fixed
        case "cover": request.initialSnapshot?.routes[0].defStatus = .cover
        case "shape": request.initialSnapshot?.routes[0].defShape = .stripe
        case "implicit-width": request.configuration.implementationConstraints = nil
        case "missing-width": request.initialSnapshot?.routes[0].segments[0].widthDBU = nil
        case "different-width": request.configuration.implementationConstraints?.routeWidth = 100
        case "via": request.initialSnapshot?.vias = [.init(id: "source-contact", netID: "in", x: 10300, y: 1500, lowerLayer: 2, upperLayer: 3, master: "hv")]
        case "different-layer":
            let index = try #require(request.initialSnapshot?.pins.firstIndex { $0.id == "TOP/in" })
            let old = try #require(request.initialSnapshot?.pins[index].topPort)
            request.initialSnapshot?.pins[index].accessLayer = 3
            request.initialSnapshot?.pins[index].topPort = .init(rectangle: old.rectangle, layer: 3, placementX: old.placementX,
                placementY: old.placementY, orientation: old.orientation, placementStatus: old.placementStatus, use: old.use)
        case "no-path": request.initialSnapshot?.blockages = [.init(x: 5000, y: 0, width: 500, height: 6000)]
        default: request.configuration.maximumRoutingCandidateChecks = 1
        }
        let before = try PhysicalDesignJSONCodec().encode(#require(request.initialSnapshot))
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil, "\(result.diagnostics)")
        #expect(try PhysicalDesignJSONCodec().encode(#require(request.initialSnapshot)) == before)
        if scenario == "no-path" { #expect(result.diagnostics.contains { $0.code.rawValue == "routing_path_unavailable" }, "\(result.diagnostics)") }
        if scenario == "budget" { #expect(result.diagnostics.contains { $0.code.rawValue == "routing_candidate_budget_exhausted" }, "\(result.diagnostics)") }
    }

    @Test("placement cannot discard fixed special wires and buffer insertion cannot split original identity", arguments: ["placement", "split"])
    func otherCellMutationRefusal(scenario: String) async throws {
        var (request, store, _) = try await fixture()
        if scenario == "placement" {
            request.stage = .placement
            request.initialSnapshot?.cells[0].placed = false
            request.initialSnapshot?.routes[0].defStatus = .fixed
        } else {
            request.configuration.ecoAction = .bufferInsertion
            request.configuration.ecoTargetNetID = "in"
            request.configuration.ecoBufferMaster = "INV"
        }
        let before = try PhysicalDesignJSONCodec().encode(#require(request.initialSnapshot))
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil, "\(result.diagnostics)")
        let code = scenario == "placement" ? "routing_special_route_protected" : "eco_special_topology_unsupported"
        #expect(result.diagnostics.contains { $0.code.rawValue == code }, "\(result.diagnostics)")
        #expect(try PhysicalDesignJSONCodec().encode(#require(request.initialSnapshot)) == before)
    }

    @Test("cancelled special routing publishes no candidate")
    func cancellation() async throws {
        var (request, store, _) = try await fixture()
        request.stage = .globalRouting
        let task = Task { try await PhysicalDesignEngine(artifactStore: store).execute(request) }
        task.cancel()
        let result = try await task.value
        #expect(result.status == .cancelled && result.artifactBindings.isEmpty)
    }

    @Test("actual CLI emits four SPECIALNETS or refuses the finite caller budget", arguments: [false, true])
    func specialRoutingCLI(exhausted: Bool) async throws {
        var (request, sourceStore, _) = try await fixture()
        request.stage = .globalRouting
        if exhausted { request.configuration.maximumRoutingCandidateChecks = 1 }
        let root = FileManager.default.temporaryDirectory.appending(path: "special-routing-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("CLI cleanup failed: \(error)") } }
        for binding in request.inputBindings {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await sourceStore.read(binding).write(to: url)
        }
        let codec = PhysicalDesignJSONCodec(), requestURL = root.appending(path: "request.json"), resultURL = root.appending(path: "result.json")
        try codec.encode(request).write(to: requestURL)
        #expect(FileManager.default.createFile(atPath: resultURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: resultURL)
        defer { do { try handle.close() } catch { Issue.record("CLI close failed: \(error)") } }
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", requestURL.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        process.waitUntilExit()
        let result = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: resultURL))
        if exhausted {
            #expect(process.terminationStatus != 0 && result.status == .blocked && result.artifactBindings.isEmpty)
            #expect(result.diagnostics.contains { $0.code.rawValue == "routing_candidate_budget_exhausted" })
        } else {
            #expect(process.terminationStatus == 0 && result.status == .completed, "\(result.diagnostics)")
            let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
            let snapshot = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
            #expect(snapshot.nets == request.initialSnapshot?.nets && snapshot.routes.count == 4 && snapshot.vias.isEmpty)
            let sourceReferences = request.processAssets.mapValues(\.reference)
            #expect(snapshot.processManifest == request.pdk.manifest && snapshot.processAssets == sourceReferences)
            let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
            let standard = try DEFLibraryReader.read(await store.read(def))
            #expect(standard.nets.isEmpty && standard.specialNets.count == 4)
            #expect(standard.specialNets.allSatisfy { $0.use == nil && !$0.routing.isEmpty && $0.routing.allSatisfy { $0.width == 200 && $0.status == .routed && $0.shape == nil } })
            for binding in result.artifactBindings { _ = try await store.read(binding) }
        }
    }

    /// Lower native geometry fixture. Full transistor-mask/LVS composition is owned by the host.
    func fixture() async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore, PhysicalDesignProcessGeometry) {
        let (_, base, store) = try await ProcessGeometryTests().fixture()
        let sourceCells = """
        VERSION 5.8 ; UNITS DATABASE MICRONS 1000 ; END UNITS
        MACRO INV CLASS CORE ; SIZE 4 BY 4 ; SYMMETRY X Y ; SITE unit ;
          PIN in DIRECTION INPUT ; USE SIGNAL ; PORT LAYER metH ; RECT 0.1 0.3 0.5 0.7 ; END END in
          PIN out DIRECTION OUTPUT ; USE SIGNAL ; PORT LAYER metH ; RECT 3.5 1.3 3.9 1.7 ; END END out
          PIN vss DIRECTION INOUT ; USE GROUND ; PORT LAYER metH ; RECT 0.1 2.3 0.5 2.7 ; END END vss
          PIN vdd DIRECTION INOUT ; USE POWER ; PORT LAYER metH ; RECT 0.1 3.3 0.5 3.7 ; END END vdd
        END INV END LIBRARY
        """
        let cells = try await store.registerInput(Data(sourceCells.utf8), relativePath: "inputs/special-cells.lef", kind: .technology, format: .lef)
        let originalTech = try #require(base.processAssets["tech"])
        let techText = try #require(String(data: await store.read(originalTech), encoding: .utf8)).replacingOccurrences(of: "SIZE 0.1 BY 1", with: "SIZE 0.1 BY 4")
        let tech = try await store.registerInput(Data(techText.utf8), relativePath: "inputs/special-tech.lef", kind: .technology, format: .lef)
        let originalManifest = try #require(base.inputBindings.first { $0.reference == base.pdk.manifest })
        var manifest = try PDKManifestCodec.decode(data: await store.read(originalManifest))
        for (id, binding) in [("cells", cells), ("tech", tech)] {
            let index = try #require(manifest.assets.firstIndex { $0.assetID == id })
            manifest.assets[index].sha256 = binding.reference.digest.hexadecimalValue
            manifest.assets[index].byteCount = Int64(binding.reference.byteCount)
        }
        let mapping = try #require(manifest.crossViewMappings.firstIndex { $0.physicalNames.contains("INV_X1") })
        manifest.crossViewMappings[mapping].physicalNames = ["INV"]
        manifest.crossViewMappings[mapping].logicalNames = ["INV"]
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/special-process.json", kind: .technology, format: .json)
        let design = try await store.registerInput(Data("module TOP(input in, input vdd, input vss, output out); INV U1(.in(in), .out(out), .vdd(vdd), .vss(vss)); endmodule\n".utf8), relativePath: "inputs/special-design.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Source geometry candidate only.\n".utf8), relativePath: "inputs/special.sdc", kind: .constraint, format: .sdc)
        var configuration = base.configuration
        configuration.rowHeight = 4000; configuration.siteWidth = 100
        configuration.ecoAction = .moveCell; configuration.ecoTargetCellID = "U1"; configuration.ecoDeltaX = 200
        configuration.preferredRoutingLayers = [2, 3]; configuration.maximumRoutingLayer = 3
        configuration.powerNetNames = ["vdd", "vss"]
        configuration.implementationConstraints = .init(routeWidth: 200, routeSpacing: 100)
        let locations: [(String, Int64, Int64)] = [("in", 10300, 1500), ("out", 13700, 2500), ("vss", 10300, 3500), ("vdd", 10300, 4500)]
        var pins: [PhysicalDesignSnapshot.Pin] = [], nets: [PhysicalDesignSnapshot.Net] = [], routes: [PhysicalDesignSnapshot.Route] = []
        for (name, x, y) in locations {
            let direction = name == "in" ? "input" : name == "out" ? "output" : "inout"
            let terminalX: Int64 = name == "out" ? 30000 : 0
            let use: DEFSpecialNet.NetUse = name == "vdd" ? .power : name == "vss" ? .ground : .signal
            pins.append(.init(id: "U1/" + name, cellID: "U1", name: name, x: x, y: y, netID: name, direction: direction, accessLayer: 2))
            pins.append(.init(id: "TOP/" + name, name: name, x: terminalX, y: y, netID: name, direction: direction, accessLayer: 2,
                topPort: .init(rectangle: .init(x: -100, y: -100, width: 200, height: 200), layer: 2,
                    placementX: terminalX, placementY: y, orientation: .n, placementStatus: .placed, use: use)))
            nets.append(.init(id: name, pinIDs: ["U1/" + name, "TOP/" + name], routingClass: .special, defUse: nil))
            routes.append(.init(id: "original_" + name, netID: name,
                segments: [.init(id: "original_" + name + "_wire", layer: 2, x1: x, y1: y, x2: terminalX, y2: y,
                    widthDBU: 200, endpointExtensions: .init(beginDBU: 0, endDBU: 0))], defStatus: .routed, defShape: nil))
        }
        let snapshot = PhysicalDesignSnapshot(topCell: "TOP", unitsPerMicron: 1000,
            die: .init(x: -100, y: 0, width: 40200, height: 10000), core: .init(x: -100, y: 0, width: 40200, height: 10000),
            rows: [.init(id: "row", originX: 0, originY: 1000, siteWidth: 100, height: 4000, siteCount: 400, siteName: "unit")],
            cells: [.init(id: "U1", master: "INV", x: 10000, y: 1000, width: 4000, height: 4000, placed: true)], pins: pins, nets: nets, routes: routes,
            implementationState: .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 50),
                .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 101)]))
        var request = PhysicalDesignRequest(runID: "special-move", inputBindings: [design, constraints, pdk, tech, cells],
            design: .init(artifact: design.reference, topDesignName: "TOP", designDigest: design.reference.digest.hexadecimalValue),
            constraints: constraints, requestedModeIDs: base.requestedModeIDs,
            pdk: .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk), processID: base.pdk.processID,
                version: base.pdk.version, digest: pdk.reference.digest.hexadecimalValue), stage: .timingECO, configuration: configuration,
            initialSnapshot: snapshot, processAssets: ["tech": tech, "cells": cells])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: snapshot.unitsPerMicron)
        request.initialSnapshot = try geometry.bind(snapshot)
        try geometry.validate(#require(request.initialSnapshot))
        return (request, store, geometry)
    }
}
