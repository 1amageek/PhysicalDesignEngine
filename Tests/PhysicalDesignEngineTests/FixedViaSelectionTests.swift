import CircuiteFoundation
import DEF
import Foundation
import LayoutIR
import LEF
import MaskGeometry
import PDKCore
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Typed fixed VIA selection", .timeLimit(.minutes(1)))
struct FixedViaSelectionTests {
    @Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
    func typedLayerOrderPreservesActualShapes(order: [Int]) async throws {
        let fixture = try await fixture(blocks: [via("fixed", order: order)])
        let source = try #require(fixture.geometry.vias["fixed"])
        #expect(source.lowerLayer == 2 && source.cutLayer == 4 && source.upperLayer == 3)
        let shapes = try fixture.geometry.viaShapes(master: "fixed", x: 1000, y: 1000)
        #expect(Set(shapes.map(\.layer)) == [2, 3, 4])
        for shape in shapes {
            let box = try #require(Region(layer: shape.layer, polygons: [shape]).boundingBox)
            let half: Int32 = shape.layer == 4 ? 25 : 100
            #expect(box.minX == 1000 - half && box.maxX == 1000 + half)
            #expect(box.minY == 1000 - half && box.maxY == 1000 + half)
        }
    }

    @Test(arguments: ["stable", "reverse", "bounds", "cut-spacing"])
    func onlyLegalCandidatesParticipateInStableSelection(scenario: String) async throws {
        let blocks: [String]
        if scenario == "bounds" { blocks = [via("a_large", metal: 20), via("z_legal")] }
        else if scenario == "cut-spacing" { blocks = [via("a_large_cut", metal: 0.2, cut: 0.1), via("z_legal")] }
        else { blocks = scenario == "reverse" ? [via("z_legal"), via("a_legal")] : [via("a_legal"), via("z_legal")] }
        let fixture = try await fixture(blocks: blocks)
        let requested = PhysicalDesignSnapshot.Via(id: "candidate", netID: "N", x: 1000, y: 1000, lowerLayer: 2, upperLayer: 3)
        let bounds = PhysicalDesignSnapshot.Rect(x: 0, y: 0, width: 10000, height: 10000)
        let obstacle = IRBoundary(layer: 4, datatype: 0, points: [
            .init(x: 1100, y: 975), .init(x: 1150, y: 975), .init(x: 1150, y: 1025),
            .init(x: 1100, y: 1025), .init(x: 1100, y: 975)])
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let selected = try PhysicalDesignFixedViaSelection.select(requested, within: bounds, geometry: fixture.geometry, budget: &budget) { _, shapes, run in
            try PhysicalDesignFixedViaSelection.cutsFit(shapes, geometry: fixture.geometry, against: [],
                sourceCuts: scenario == "cut-spacing" ? [obstacle] : [], budget: &run)
        }
        #expect(selected?.master == (scenario == "bounds" || scenario == "cut-spacing" ? "z_legal" : "a_legal"))
        #expect(budget.checks > 0 && budget.checks <= budget.capacity)
        if scenario == "stable" {
            var explicit = requested; explicit.master = "z_legal"
            let preserved = try PhysicalDesignFixedViaSelection.select(explicit, within: bounds, geometry: fixture.geometry, budget: &budget) { _, _, _ in true }
            #expect(preserved?.master == "z_legal")
            #expect(try fixture.geometry.resolveVia(explicit, within: bounds) == explicit)
        }
    }

    @Test func unknownIdentityBudgetAndCancellationCannotSelect() async throws {
        let fixture = try await fixture(blocks: [via("a_legal"), via("z_legal")])
        let bounds = PhysicalDesignSnapshot.Rect(x: 0, y: 0, width: 10000, height: 10000)
        let requested = PhysicalDesignSnapshot.Via(id: "candidate", netID: "N", x: 1000, y: 1000, lowerLayer: 2, upperLayer: 3)
        #expect(throws: PhysicalDesignTechnologyError.self) { try fixture.geometry.resolveVia(requested, within: bounds) }
        var unknown = requested; unknown.master = "missing"
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try PhysicalDesignFixedViaSelection.select(unknown, within: bounds, geometry: fixture.geometry, budget: &budget) { _, _, _ in true }
        }
        var limited = PhysicalDesignRoutingWorkBudget(caller: 1)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try PhysicalDesignFixedViaSelection.select(requested, within: bounds, geometry: fixture.geometry, budget: &limited) { _, _, _ in true }
        }
        let sourceCuts = (0..<1000).map { index -> IRBoundary in
            let x = Int32(2000 + index * 100)
            return .init(layer: 4, datatype: 0, points: [.init(x: x, y: 975), .init(x: x + 50, y: 975),
                .init(x: x + 50, y: 1025), .init(x: x, y: 1025), .init(x: x, y: 975)])
        }
        var cutLimited = PhysicalDesignRoutingWorkBudget(caller: 200)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try PhysicalDesignFixedViaSelection.select(requested, within: bounds, geometry: fixture.geometry, budget: &cutLimited) { _, shapes, run in
                try PhysicalDesignFixedViaSelection.cutsFit(shapes, geometry: fixture.geometry, against: [], sourceCuts: sourceCuts, budget: &run)
            }
        }
        #expect(cutLimited.checks <= 200)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var run = PhysicalDesignRoutingWorkBudget(caller: nil)
            do {
                _ = try PhysicalDesignFixedViaSelection.select(requested, within: bounds, geometry: fixture.geometry, budget: &run) { _, _, _ in true }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        #expect(await task.value)
    }

    @Test func malformedTypedStacksCannotEnterTheCatalogue() async throws {
        let fixture = try await fixture(blocks: [via("fixed")])
        let source = try #require(fixture.geometry.vias["fixed"]?.definition)
        let mapping: [String: Int16] = ["metH": 2, "metV": 3, "cutHV": 4]
        for duplicate in [false, true] {
            var invalid = source
            if duplicate { invalid.layers[2] = invalid.layers[0] }
            else { invalid.layers.removeLast() }
            #expect(throws: PhysicalDesignTechnologyError.self) {
                try PhysicalDesignFixedViaStack(via: invalid, layerMap: mapping, layers: fixture.geometry.layers,
                    sourceLayers: fixture.geometry.sourceLayers)
            }
        }
    }

    @Test func retainedCutsUseTheSameDistinctPrimitiveSeparation() async throws {
        let fixture = try await fixture(blocks: [via("fixed")])
        let first = PhysicalDesignSnapshot.Via(id: "first", netID: "N", x: 1000, y: 1000, lowerLayer: 2, upperLayer: 3, master: "fixed")
        for offsetY: Int64 in [0, 50] {
            var touching = first; touching.id = "touching"; touching.x += 50; touching.y += offsetY
            #expect(throws: PhysicalDesignTechnologyError.self) { try fixture.geometry.validateRoutingCuts([first, touching]) }
        }
        var exactGap = first; exactGap.id = "exact-gap"; exactGap.x += 100
        try fixture.geometry.validateRoutingCuts([first, exactGap])
    }

    @Test(arguments: ["cut-first", "multiple", "reverse", "bounds", "unused-formula", "all-illegal", "unknown"])
    func actualAPIAndCLIPersistExactMasterOrFailAtomically(scenario: String) async throws {
        let blocks: [String]
        switch scenario {
        case "cut-first": blocks = [via("a_legal", order: [1, 0, 2])]
        case "bounds": blocks = [via("a_large", metal: 20), via("z_legal")]
        case "all-illegal": blocks = [via("a_large", metal: 20), via("z_large", metal: 21)]
        case "reverse": blocks = [via("z_legal"), via("a_legal", order: [2, 1, 0])]
        case "unused-formula": blocks = [via("a_legal"), """
            VIARULE a_legal GENERATE
              LAYER metH ; ENCLOSURE 0.06 0.03 ;
              LAYER metV ; ENCLOSURE -0.01 0.04 ;
              LAYER cutHV ; RECT -0.1 -0.2 0.3 0.4 ; SPACING 0.5 BY 0.8 ;
            END a_legal
            """]
        default: blocks = [via("a_legal"), via("z_legal")]
        }
        let fixture = try await fixture(blocks: blocks)
        if scenario == "unused-formula" {
            let source = try LEFLibraryReader.read(await fixture.store.read(try #require(fixture.request.processAssets["tech"])))
            #expect(source.viaGenerationRules.count == 1 && source.viaGenerationRules[0].name == "a_legal")
            #expect(fixture.geometry.vias["a_legal"]?.definition.isGenerate == false)
        }
        var request = fixture.request
        if scenario == "unknown" {
            request.initialSnapshot?.vias = [.init(id: "unknown", netID: "N", x: 2500, y: 2500, lowerLayer: 2, upperLayer: 3, master: "missing")]
        }
        let failed = scenario == "all-illegal" || scenario == "unknown"
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request)
        #expect(result.status == (failed ? .blocked : .completed), "\(result.diagnostics)")
        if failed {
            #expect(result.artifactBindings.isEmpty && result.payload.physicalDesign == nil)
            #expect(await fixture.store.data(at: "runs/\(request.runID)/physical-design/globalRouting/revision.json") == nil)
        } else {
            let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
                from: await fixture.store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
            try verify(output, expected: scenario == "bounds" ? "z_legal" : "a_legal", geometry: fixture.geometry)
            let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
            let parsed = try DEFLibraryReader.read(await fixture.store.read(def))
            #expect(parsed.nets.flatMap(\.routing).compactMap(\.viaName).allSatisfy { $0 == output.vias[0].master })
            var resumed = PhysicalDesignRequest(runID: "fixed-via-eco", inputBindings: request.inputBindings + [try #require(result.payload.physicalDesign?.layoutArtifact)],
                design: request.design, constraints: request.constraints, requestedModeIDs: request.requestedModeIDs, pdk: request.pdk,
                inputLayout: result.payload.physicalDesign, stage: .timingECO, configuration: request.configuration, processAssets: request.processAssets)
            resumed.configuration.ecoAction = .rerouteNet; resumed.configuration.ecoTargetNetID = "N"
            let eco = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(resumed)
            #expect(eco.status == .completed, "\(eco.diagnostics)")
            let reloaded = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
                from: await fixture.store.read(try #require(eco.payload.physicalDesign?.layoutArtifact)))
            try verify(reloaded, expected: scenario == "bounds" ? "z_legal" : "a_legal", geometry: fixture.geometry)
        }
        try await cli(request, store: fixture.store, failed: failed, expected: scenario == "bounds" ? "z_legal" : "a_legal", geometry: fixture.geometry)
    }

    private func verify(_ output: PhysicalDesignSnapshot, expected: String, geometry: PhysicalDesignProcessGeometry) throws {
        #expect(!output.vias.isEmpty && output.vias.allSatisfy { $0.master == expected })
        try geometry.validate(output)
        for contact in output.vias {
            #expect(try geometry.resolveVia(contact, within: #require(output.core)) == contact)
        }
    }

    private func via(_ name: String, order: [Int] = [0, 1, 2], metal: Double = 0.1, cut: Double = 0.025) -> String {
        let layers = ["LAYER metH ; RECT \(-metal) \(-metal) \(metal) \(metal) ;",
                      "LAYER cutHV ; RECT \(-cut) \(-cut) \(cut) \(cut) ;",
                      "LAYER metV ; RECT \(-metal) \(-metal) \(metal) \(metal) ;"]
        return "VIA \(name) DEFAULT\n" + order.map { layers[$0] }.joined(separator: "\n") + "\nRESISTANCE 0.75 ; END \(name)\n"
    }

    private func fixture(blocks: [String]) async throws -> (geometry: PhysicalDesignProcessGeometry, request: PhysicalDesignRequest, store: InMemoryPhysicalDesignArtifactStore) {
        let support = ProcessGeometryTests()
        let (base, store) = try await support.fixtureSources(routingPorts: true)
        let old = try #require(base.processAssets["tech"])
        let text = try #require(String(data: await store.read(old), encoding: .utf8))
        let begin = try #require(text.range(of: "VIA hv DEFAULT"))
        let end = try #require(text.range(of: "END hv"))
        let source = text.replacingCharacters(in: begin.lowerBound..<end.upperBound, with: blocks.joined(separator: "\n"))
        let binding = try await store.registerInput(Data(source.utf8), relativePath: "inputs/fixed-vias.lef", kind: .technology, format: .lef)
        let oldManifest = try base.requireBinding(for: base.pdk.manifest)
        var manifest = try PDKManifestCodec.decode(data: await store.read(oldManifest))
        let asset = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[asset].sha256 = binding.reference.digest.hexadecimalValue
        manifest.assets[asset].byteCount = Int64(source.utf8.count)
        manifest.assets[asset].path = "fixed-vias.lef"
        let manifestBinding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/fixed-vias-process.json", kind: .technology, format: .json)
        let design = try await store.registerInput(Data("module fixture_top(); wire N; INV_X1 U1(.Y(N)); INV_X1 U2(.A(N)); endmodule\n".utf8), relativePath: "inputs/fixed-vias.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Exact geometry only.\n".utf8), relativePath: "inputs/fixed-vias.sdc", kind: .constraint, format: .sdc)
        var prepared = support.nativeRequest(base)
        var snapshot = try #require(prepared.initialSnapshot)
        snapshot.cells = [.init(id: "U1", master: "INV_X1", x: 500, y: 1000, width: 2000, height: 1000, placed: true),
                          .init(id: "U2", master: "INV_X1", x: 5000, y: 3000, width: 2000, height: 1000, placed: true, orientation: .fn)]
        snapshot.pins = [.init(id: "U1/Y", cellID: "U1", name: "Y", x: 1700, y: 1100, netID: "N", direction: "output", accessLayer: 2),
                         .init(id: "U2/A", cellID: "U2", name: "A", x: 6300, y: 3100, netID: "N", direction: "input", accessLayer: 2)]
        snapshot.nets = [.init(id: "N", pinIDs: ["U1/Y", "U2/A"])]
        snapshot.rows = [1000, 3000].map { .init(id: "row_\($0)", originX: 0, originY: Int64($0), siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit") }
        snapshot.blockages = [.init(x: 3000, y: 1100, width: 600, height: 2400)]
        snapshot.implementationState = .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 50),
                                                     .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 25)])
        prepared = PhysicalDesignRequest(runID: "fixed-via-routing", inputBindings: [manifestBinding, design, constraints],
            design: .init(artifact: design.reference, topDesignName: base.design.topDesignName, designDigest: design.reference.digest.hexadecimalValue),
            constraints: constraints, requestedModeIDs: base.requestedModeIDs,
            pdk: try .init(manifest: manifestBinding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: manifestBinding), processID: base.pdk.processID, version: base.pdk.version),
            stage: .globalRouting, configuration: prepared.configuration, initialSnapshot: snapshot,
            processAssets: ["tech": binding, "cells": try #require(base.processAssets["cells"])])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: prepared, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: prepared, units: 1000)
        prepared.initialSnapshot = try geometry.bind(snapshot)
        return (geometry, prepared, store)
    }

    private func cli(_ request: PhysicalDesignRequest, store: InMemoryPhysicalDesignArtifactStore, failed: Bool,
                     expected: String, geometry: PhysicalDesignProcessGeometry) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "fixed-via-cli-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("VIA CLI cleanup failed: \(error)") } }
        for binding in request.inputBindings {
            let path = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await store.read(binding).write(to: path)
        }
        let codec = PhysicalDesignJSONCodec(), requestURL = root.appending(path: "request.json"), resultURL = root.appending(path: "result.json")
        try codec.encode(request).write(to: requestURL)
        #expect(FileManager.default.createFile(atPath: resultURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: resultURL)
        defer { do { try handle.close() } catch { Issue.record("VIA CLI close failed: \(error)") } }
        let process = Process(); process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", requestURL.path, "--project-root", root.path]; process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        // Observed termination completes the async wait; a second run-loop wait can miss its notification.
        let result = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: resultURL))
        #expect(result.status == (failed ? .blocked : .completed))
        #expect((process.terminationStatus != 0) == failed)
        if failed { #expect(result.artifactBindings.isEmpty && result.payload.physicalDesign == nil) }
        else {
            let output = try codec.decode(PhysicalDesignSnapshot.self, from: Data(contentsOf: root.appending(path: #require(result.payload.physicalDesign?.layoutArtifact.path))))
            try verify(output, expected: expected, geometry: geometry)
            let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
            let parsed = try DEFLibraryReader.read(Data(contentsOf: root.appending(path: def.path)))
            #expect(parsed.nets.flatMap(\.routing).compactMap(\.viaName).allSatisfy { $0 == expected })
        }
    }
}
