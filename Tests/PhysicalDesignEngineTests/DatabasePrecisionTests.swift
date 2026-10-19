import Foundation
import Testing
import DEF
import PhysicalDesignEngine
@testable import PhysicalDesignCore

@Suite("Native source database precision", .timeLimit(.minutes(1)))
struct DatabasePrecisionTests {
    private func fixture(_ scenario: String) async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore) {
        let support = ProcessGeometryTests()
        let source = scenario == "implicit-cell" ? "database-implicit-cell" : (scenario.hasSuffix("implicit-tech") ? "database-implicit-tech" : (scenario == "conflict" ? "database-conflict" : "valid"))
        let (base, store) = try await support.fixtureSources(source)
        var request = support.nativeRequest(base)
        request.runID = "database-\(scenario)"
        if scenario.hasSuffix("finer") { request.initialSnapshot?.unitsPerMicron = 2000 }
        if scenario == "nondivisible" { request.initialSnapshot?.unitsPerMicron = 400 }
        if scenario.hasSuffix("coarser") {
            request.initialSnapshot?.unitsPerMicron = 200
            request.initialSnapshot?.die = .init(x: 0, y: 0, width: 2000, height: 2000)
            request.initialSnapshot?.core = .init(x: 0, y: 0, width: 2000, height: 2000)
            request.initialSnapshot?.cells[0].x = 100; request.initialSnapshot?.cells[0].y = 40
            request.initialSnapshot?.cells[0].width = 400; request.initialSnapshot?.cells[0].height = 200
            request.initialSnapshot?.pins[0].x = 440; request.initialSnapshot?.pins[0].y = 80
            request.configuration.siteWidth = 20; request.configuration.rowHeight = 200
            request.configuration.implementationConstraints?.routeWidth = 20
            request.configuration.implementationConstraints?.routeSpacing = 20
        }
        if scenario.hasPrefix("tech-only") {
            request.processAssets.removeValue(forKey: "cells")
            request.initialSnapshot?.cells = []; request.initialSnapshot?.pins = []
        }
        let design = try await store.registerInput(Data("module fixture_top(); endmodule\n".utf8), relativePath: "inputs/database-design.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Explicit database precision profile\n".utf8), relativePath: "inputs/database.sdc", kind: .constraint, format: .sdc)
        request.design.artifact = design.reference; request.design.designDigest = design.reference.digest.hexadecimalValue
        request.constraints = constraints
        request.inputBindings = request.inputBindings.filter { $0.reference == request.pdk.manifest } + [design, constraints] + request.processAssets.values.sorted { $0.path < $1.path }
        request.inputs = request.inputBindings.map(\.reference)
        return (request, store)
    }

    @Test(arguments: ["explicit", "implicit-cell", "coarser", "implicit-tech", "conflict", "finer", "nondivisible", "tech-only-coarser", "tech-only-finer", "tech-only-implicit-tech"])
    func api(_ scenario: String) async throws {
        let (request, store) = try await fixture(scenario)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        guard ["explicit", "implicit-cell", "coarser", "tech-only-coarser"].contains(scenario) else {
            #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
            #expect(result.diagnostics.contains { $0.summary.contains("DATABASE") }, "\(result.diagnostics)")
            return
        }
        #expect(result.status == .completed, "\(result.diagnostics)")
        let reference = try #require(result.payload.physicalDesign)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
        let units = scenario.hasSuffix("coarser") ? 200 : 1000
        #expect(output.unitsPerMicron == units)
        if scenario.hasPrefix("tech-only") { #expect(output.cells.isEmpty) }
        else { #expect(output.cells[0].width == Int64(2 * units)) }
        let document = try DEFLibraryReader.read(await store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })))
        #expect(document.dbuPerMicron == Double(units))
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        #expect(try inputs.databaseUnitsPerMicron(for: units) == 1000)
        if scenario == "implicit-cell" {
            #expect(inputs.cellViews.values.allSatisfy { !$0.hasDatabaseUnitsDeclaration && $0.dbuPerMicron == 100 })
        }
        let again = try await PhysicalDesignEngine(artifactStore: store).execute(resume(request, from: reference))
        #expect(again.status == .completed, "\(again.diagnostics)")
        for binding in again.artifactBindings { _ = try await store.read(binding) }
    }

    @Test(arguments: ["explicit", "implicit-cell", "coarser", "implicit-tech", "conflict", "finer", "nondivisible", "tech-only-coarser", "tech-only-finer", "tech-only-implicit-tech"])
    func cli(_ scenario: String) async throws {
        let (request, memory) = try await fixture(scenario)
        let root = FileManager.default.temporaryDirectory.appending(path: "database-precision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in request.inputBindings {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: url)
        }
        let (result, exit) = try invoke(request, root: root)
        guard ["explicit", "implicit-cell", "coarser", "tech-only-coarser"].contains(scenario) else {
            #expect(exit != 0 && result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
            #expect(result.diagnostics.contains { $0.summary.contains("DATABASE") })
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "runs/\(request.runID)/physical-design/floorplan/revision.json").path))
            return
        }
        #expect(exit == 0 && result.status == .completed, "\(result.diagnostics)")
        let reference = try #require(result.payload.physicalDesign)
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
        let document = try DEFLibraryReader.read(await store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })))
        #expect(output.unitsPerMicron == (scenario.hasSuffix("coarser") ? 200 : 1000))
        #expect(document.dbuPerMicron == Double(output.unitsPerMicron))
        let (again, resumedExit) = try invoke(resume(request, from: reference), root: root)
        #expect(resumedExit == 0 && again.status == .completed, "\(again.diagnostics)")
        for binding in again.artifactBindings { _ = try await store.read(binding) }
    }

    @Test func exactProjectionFrameAndAgreement() async throws {
        let (geometry, base, store) = try await ProcessGeometryTests().fixture()
        var snapshot = try geometry.bind(.init(topCell: base.design.topDesignName))
        snapshot.unitsPerMicron = 200
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.bind(snapshot) }
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.validate(snapshot) }
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: base, store: store))
        var second = try #require(inputs.technologyViews.values.first)
        second.dbuPerMicron = 2000
        var views = inputs.technologyViews; views["contradictory"] = second
        let ambiguous = PhysicalDesignProcessInputs(manifest: inputs.manifest, technologyViews: views, cellViews: inputs.cellViews)
        #expect(throws: PhysicalDesignTechnologyError.self) { try ambiguous.databaseUnitsPerMicron(for: 1000) }
    }

    private func resume(_ request: PhysicalDesignRequest, from reference: PhysicalDesignReference) -> PhysicalDesignRequest {
        var result = request; result.runID += "-resume"; result.initialSnapshot = nil; result.inputLayout = reference
        result.inputBindings.append(reference.layoutArtifact); result.inputs.append(reference.layoutArtifact.reference)
        return result
    }

    private func invoke(_ request: PhysicalDesignRequest, root: URL) throws -> (PhysicalDesignResult, Int32) {
        let path = root.appending(path: request.runID + ".json"), codec = PhysicalDesignJSONCodec()
        try codec.encode(request).write(to: path)
        let process = Process(); process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", path.path, "--project-root", root.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (try codec.decode(PhysicalDesignResult.self, from: bytes), process.terminationStatus)
    }
}
