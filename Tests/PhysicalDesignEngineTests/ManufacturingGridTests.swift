import Foundation
import Testing
import DEF
import PhysicalDesignEngine
@testable import PhysicalDesignCore

@Suite("Native manufacturing grid", .timeLimit(.minutes(1)))
struct ManufacturingGridTests {
    private func request(_ scenario: String) async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore) {
        let support = ProcessGeometryTests()
        let sourceScenario = scenario == "source-via" ? "manufacturing-grid-via" : (scenario == "source" ? "manufacturing-grid-port" : (scenario == "conflict" ? "manufacturing-grid-conflict" : "valid"))
        let (base, store) = try await support.fixtureSources(sourceScenario, grid: scenario == "sub-dbu" ? "0.0005" : "0.005")
        var request = support.nativeRequest(base)
        request.runID = "grid-\(scenario)"
        if scenario == "input" || scenario == "retained-input" { request.initialSnapshot?.cells[0].x += 1 }
        if scenario == "output" || scenario == "tech-only-output" { request.initialSnapshot?.core = nil; request.configuration.coreMargin = 1 }
        if scenario.hasPrefix("tech-only") {
            request.processAssets.removeValue(forKey: "cells")
            request.initialSnapshot?.cells = []
            request.initialSnapshot?.pins = []
        }
        if scenario == "via" {
            request.initialSnapshot?.nets = [.init(id: "N", pinIDs: [])]
            request.initialSnapshot?.vias = [.init(id: "V", netID: "N", x: 1001, y: 1000, lowerLayer: 2, upperLayer: 3, master: "hv")]
        }
        // Real CLI inputs must be retrievable, including the otherwise opaque design and SDC.
        let design = try await store.registerInput(Data("grid test design".utf8), relativePath: "inputs/grid-design.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# explicit geometry profile\n".utf8), relativePath: "inputs/grid.sdc", kind: .constraint, format: .sdc)
        request.design.artifact = design.reference
        request.design.designDigest = design.reference.digest.hexadecimalValue
        request.constraints = constraints
        request.inputBindings = request.inputBindings.filter { $0.reference == request.pdk.manifest } + [design, constraints] + request.processAssets.values.sorted { $0.path < $1.path }
        request.inputs = request.inputBindings.map(\.reference)
        if scenario == "retained-input" {
            let layout = try await store.registerInput(try PhysicalDesignJSONCodec().encode(request.initialSnapshot), relativePath: "inputs/off-grid-revision.json", kind: .layout, format: .json)
            request.initialSnapshot = nil
            request.inputLayout = .init(layoutArtifact: layout, topCell: base.design.topDesignName, layoutDigest: layout.reference.digest.hexadecimalValue)
            request.inputBindings.append(layout)
            request.inputs.append(layout.reference)
        }
        return (request, store)
    }

    @Test(arguments: ["valid", "input", "retained-input", "via", "output", "source", "source-via", "sub-dbu", "conflict", "tech-only", "tech-only-output"])
    func api(_ scenario: String) async throws {
        let (request, store) = try await request(scenario)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        if scenario != "valid" && scenario != "tech-only" {
            #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
            #expect(result.diagnostics.contains { $0.summary.contains("MANUFACTURINGGRID") }, "\(result.diagnostics)")
            #expect(await store.data(at: "runs/\(request.runID)/physical-design/floorplan/revision.json") == nil)
            return
        }
        let reference = try #require(result.payload.physicalDesign)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
        if scenario == "tech-only" { #expect(output.metadata["technologyLEFContentIDs"] != nil) }
        else { #expect(output.processAssets == request.processAssets.mapValues(\.reference)) }
        let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        #expect(try DEFLibraryReader.read(await store.read(def)).components.count == output.cells.count)
        let resumed = resume(request, from: reference, runID: "grid-api-resume")
        let again = try await PhysicalDesignEngine(artifactStore: store).execute(resumed)
        #expect(again.status == .completed, "\(again.diagnostics)")
        for binding in again.artifactBindings { _ = try await store.read(binding) }
    }

    @Test(arguments: ["valid", "input", "retained-input", "via", "output", "source", "source-via", "sub-dbu", "conflict", "tech-only", "tech-only-output"])
    func cli(_ scenario: String) async throws {
        let (request, memory) = try await request(scenario)
        let root = FileManager.default.temporaryDirectory.appending(path: "manufacturing-grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in request.inputBindings + Array(request.processAssets.values) {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: url)
        }
        let (result, exit) = try invoke(request, root: root)
        if scenario != "valid" && scenario != "tech-only" {
            #expect(exit != 0 && result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
            #expect(result.diagnostics.contains { $0.summary.contains("MANUFACTURINGGRID") })
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "runs/\(request.runID)/physical-design/floorplan/revision.json").path))
            return
        }
        #expect(exit == 0 && result.status == .completed, "\(result.diagnostics)")
        let reference = try #require(result.payload.physicalDesign)
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
        if scenario == "tech-only" { #expect(output.metadata["technologyLEFContentIDs"] != nil) }
        else { #expect(output.processAssets == request.processAssets.mapValues(\.reference)) }
        _ = try DEFLibraryReader.read(await store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })))
        let (again, resumedExit) = try invoke(resume(request, from: reference, runID: "grid-cli-resume"), root: root)
        #expect(resumedExit == 0 && again.status == .completed, "\(again.diagnostics)")
        for binding in again.artifactBindings { _ = try await store.read(binding) }
    }

    @Test func footprintRatherThanCenterline() async throws {
        let (base, store) = try await ProcessGeometryTests().fixtureSources(grid: "0.01")
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: base, store: store))
        let grid = try PhysicalDesignManufacturingGrid(inputs: inputs, units: 1000)
        var snapshot = PhysicalDesignSnapshot(topCell: base.design.topDesignName)
        snapshot.routes = [.init(id: "R", netID: "N", segments: [.init(id: "S", layer: 2,
            x1: 100, y1: 103, x2: 200, y2: 103, widthDBU: 6, endpointExtensions: .init(beginDBU: 0, endDBU: 0))])]
        #expect(throws: PhysicalDesignTechnologyError.self) { try grid.validate(snapshot) }
        snapshot.routes[0].segments[0].widthDBU = 10
        snapshot.routes[0].segments[0].y1 = 105
        snapshot.routes[0].segments[0].y2 = 105
        try grid.validate(snapshot)
        snapshot.routes[0].segments[0].widthDBU = nil
        #expect(throws: PhysicalDesignTechnologyError.self) { try grid.validate(snapshot) }
    }

    @Test(arguments: ["die", "core", "row", "cell", "power", "fill", "route-cap"])
    func materialVertices(_ kind: String) async throws {
        let (base, store) = try await ProcessGeometryTests().fixtureSources(grid: "0.005")
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: base, store: store))
        let grid = try PhysicalDesignManufacturingGrid(inputs: inputs, units: 1000)
        var snapshot = PhysicalDesignSnapshot(topCell: base.design.topDesignName)
        let bad = PhysicalDesignSnapshot.Rect(x: -101, y: 0, width: 100, height: 100)
        switch kind {
        case "die": snapshot.die = bad
        case "core": snapshot.core = bad
        case "row": snapshot.rows = [.init(id: "row", originX: -101, originY: 0, siteWidth: 100, height: 100, siteCount: 2)]
        case "cell": snapshot.cells = [.init(id: "cell", master: "INV_X1", x: -101, y: 0, width: 100, height: 100)]
        case "power": snapshot.powerStructures = [.init(id: "power", netID: "N", kind: "strap", layer: 2, geometry: bad)]
        case "fill": snapshot.fills = [.init(id: "fill", layer: 2, geometry: bad)]
        default: snapshot.routes = [.init(id: "route", netID: "N", segments: [.init(id: "cap", layer: 2,
            x1: -100, y1: 100, x2: 200, y2: 100, widthDBU: 100, endpointExtensions: .init(beginDBU: 1, endDBU: 0))])]
        }
        #expect(throws: PhysicalDesignTechnologyError.self) { try grid.validate(snapshot) }
        try grid.validate(-100, field: "negative aligned coordinate")
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try grid.validate(.init(x: .max, y: 0, width: 5, height: 5), field: "overflow")
        }
    }

    @Test @MainActor func cancellationRemainsExplicit() async throws {
        let (base, store) = try await ProcessGeometryTests().fixtureSources(grid: "0.005")
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: base, store: store))
        let grid = try PhysicalDesignManufacturingGrid(inputs: inputs, units: 1000)
        let task = Task { try grid.validate(PhysicalDesignSnapshot(topCell: "cancelled")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func resume(_ request: PhysicalDesignRequest, from reference: PhysicalDesignReference, runID: String) -> PhysicalDesignRequest {
        var resumed = request
        resumed.runID = runID
        resumed.initialSnapshot = nil
        resumed.inputLayout = reference
        resumed.inputBindings.append(reference.layoutArtifact)
        resumed.inputs.append(reference.layoutArtifact.reference)
        return resumed
    }

    private func invoke(_ request: PhysicalDesignRequest, root: URL) throws -> (PhysicalDesignResult, Int32) {
        let url = root.appending(path: "\(request.runID).json")
        let codec = PhysicalDesignJSONCodec()
        try codec.encode(request).write(to: url)
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", url.path, "--project-root", root.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try codec.decode(PhysicalDesignResult.self, from: bytes), process.terminationStatus)
    }
}
