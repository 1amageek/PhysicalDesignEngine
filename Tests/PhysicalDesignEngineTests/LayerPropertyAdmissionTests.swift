import Foundation
import Testing
import DEF
import PhysicalDesignEngine
@testable import PhysicalDesignCore

@Suite("Native layer property capability admission", .timeLimit(.minutes(1)))
struct LayerPropertyAdmissionTests {
    @Test(arguments: ["valid", "unknown", "library", "purpose", "subtype", "unmapped", "tech-only-purpose"])
    func apiAndCLI(_ scenario: String) async throws {
        let support = ProcessGeometryTests()
        let (base, memory) = try await support.fixtureSources("layer-property-" + (scenario == "tech-only-purpose" ? "purpose" : scenario))
        var request = support.nativeRequest(base)
        if scenario == "tech-only-purpose" {
            request.processAssets.removeValue(forKey: "cells")
            request.initialSnapshot?.cells = []
            request.initialSnapshot?.pins = []
        }
        let design = try await memory.registerInput(Data("module fixture_top(); endmodule".utf8), relativePath: "inputs/property.v", kind: .netlist, format: .verilog)
        let constraints = try await memory.registerInput(Data("# Property admission profile".utf8), relativePath: "inputs/property.sdc", kind: .constraint, format: .sdc)
        request.design.artifact = design.reference
        request.design.designDigest = design.reference.digest.hexadecimalValue
        request.constraints = constraints
        request.inputBindings = request.inputBindings.filter { $0.reference == request.pdk.manifest }
            + [design, constraints] + request.processAssets.values.sorted { $0.path < $1.path }
        request.inputs = request.inputBindings.map(\.reference)
        let root = FileManager.default.temporaryDirectory.appending(path: "layer-property-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in request.inputBindings {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: url)
        }
        let files = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        for cli in [false, true] {
            request.runID = "layer-property-\(scenario)-\(cli)"
            let result: PhysicalDesignResult
            if cli { result = try await invoke(request, root: root) }
            else { result = try await PhysicalDesignEngine(artifactStore: memory).execute(request) }
            let store: any PhysicalDesignArtifactStore = cli ? files : memory
            if scenario != "valid" {
                #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
                #expect(result.diagnostics.contains { $0.summary.contains("PROPERTY") || $0.summary.contains("property") || $0.summary.contains("LEF58_TYPE") }, "\(result.diagnostics)")
                let relative = "runs/\(request.runID)/physical-design/floorplan/revision.json"
                if cli { #expect(!FileManager.default.fileExists(atPath: root.appending(path: relative).path)) }
                else { #expect(await memory.data(at: relative) == nil) }
                continue
            }
            #expect(result.status == .completed, "\(result.diagnostics)")
            let reference = try #require(result.payload.physicalDesign)
            let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
            #expect(output.processAssets == request.processAssets.mapValues(\.reference))
            let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
            let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: output.unitsPerMicron)
            #expect(geometry.sourceLayers[5]?.subtype == .nwell)
            #expect(geometry.sourceLayers[5]?.properties.first?.name == "LEF58_TYPE")
            try geometry.validate(output)
            let def = try DEFLibraryReader.read(await store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })))
            #expect(def.components.count == output.cells.count)
            var resumed = request
            resumed.runID += "-resume"
            resumed.initialSnapshot = nil
            resumed.inputLayout = reference
            resumed.inputBindings.append(reference.layoutArtifact)
            resumed.inputs.append(reference.layoutArtifact.reference)
            let again: PhysicalDesignResult
            if cli { again = try await invoke(resumed, root: root) }
            else { again = try await PhysicalDesignEngine(artifactStore: memory).execute(resumed) }
            #expect(again.status == .completed, "\(again.diagnostics)")
            for binding in again.artifactBindings { _ = try await store.read(binding) }
        }
    }

    @Test func unmappedPropertyRulesStillReject() async throws {
        let (base, store) = try await ProcessGeometryTests().fixtureSources("layer-property-unmapped")
        await #expect(throws: PhysicalDesignTechnologyError.self) {
            _ = try await PhysicalDesignProcessInputs.load(request: base, store: store)
        }
    }

    private func invoke(_ request: PhysicalDesignRequest, root: URL) async throws -> PhysicalDesignResult {
        let codec = PhysicalDesignJSONCodec(), source = root.appending(path: request.runID + ".json")
        let target = root.appending(path: request.runID + "-result.json")
        try codec.encode(request).write(to: source)
        #expect(FileManager.default.createFile(atPath: target.path, contents: nil))
        let handle = try FileHandle(forWritingTo: target)
        defer { do { try handle.close() } catch { Issue.record(error) } }
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", source.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        let result = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: target))
        #expect((process.terminationStatus == 0) == (result.status == .completed))
        return result
    }
}
