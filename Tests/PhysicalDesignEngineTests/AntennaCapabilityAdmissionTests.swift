import Foundation
import LEF
import PDKCore
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Native retained antenna capability admission", .timeLimit(.minutes(1)))
struct AntennaCapabilityAdmissionTests {
    @Test(arguments: ["mapped", "explicit", "model-only", "oxide", "unmapped", "cell", "technology-only", "absent"])
    func apiAndCLI(_ scenario: String) async throws {
        let (request, memory) = try await fixture(scenario)
        let root = FileManager.default.temporaryDirectory.appending(path: "antenna-admission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in request.inputBindings {
            let path = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: path)
        }
        for cli in [false, true] {
            var operation = request
            operation.runID = "antenna-\(scenario)-\(cli)"
            let result: PhysicalDesignResult
            if cli { result = try await invoke(operation, root: root) }
            else { result = try await PhysicalDesignEngine(artifactStore: memory).execute(operation) }
            Attachment.record(Array(try PhysicalDesignJSONCodec().encode(result)), named: operation.runID + "-result.json")
            #expect(result.provenance.producer.version == NativePhysicalDesignExecutor.currentImplementationVersion)
            if ["absent", "mapped", "explicit", "model-only"].contains(scenario) {
                #expect(result.status == .completed, "\(result.diagnostics)")
                let output = try #require(result.payload.physicalDesign)
                let store: any PhysicalDesignArtifactStore = cli ? FileSystemPhysicalDesignArtifactStore(projectRoot: root) : memory
                let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(output.layoutArtifact))
                #expect(snapshot.processAssets == request.processAssets.mapValues(\.reference))
                let manifestBinding = try #require(result.artifactBindings.first { $0.logicalID.hasSuffix("manifest") })
                let manifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self, from: await store.read(manifestBinding))
                if scenario == "absent" { #expect(manifest.sourceAntennaMeasurementEvidence == nil) }
                else {
                    #expect(manifest.sourceAntennaMeasurementEvidence?.coverage == .unassessed)
                    #expect(manifest.sourceAntennaMeasurementEvidence?.checks.isEmpty == true)
                    #expect(manifest.claims.production == .blocked)
                }

            } else {
                #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
                #expect(result.diagnostics.contains {
                    $0.code.rawValue == "physical_technology_unsupported" && $0.summary.contains("antenna statements")
                }, "\(result.diagnostics)")
                let path = "runs/\(operation.runID)/physical-design/floorplan/revision.json"
                if cli { #expect(!FileManager.default.fileExists(atPath: root.appending(path: path).path)) }
                else { #expect(await memory.data(at: path) == nil) }
            }
        }
    }

    @Test func directGeometryCannotBypassUnmappedDeclarations() async throws {
        let (base, store) = try await fixture("absent")
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: base, store: store))
        var views = inputs.technologyViews
        let extra = try LEFLibraryReader.read(Data("LAYER unused TYPE CUT ; ANTENNAMODEL OXIDE4 ; END unused END LIBRARY".utf8))
        views["tech"]?.layers.append(contentsOf: extra.layers)
        let retained = PhysicalDesignProcessInputs(manifest: inputs.manifest, technologyViews: views, cellViews: inputs.cellViews)
        do {
            _ = try PhysicalDesignProcessGeometry(inputs: retained, request: base, units: 1000)
            Issue.record("Retained unmapped antenna declarations must not construct Native geometry.")
        } catch PhysicalDesignTechnologyError.unsupported(let reason) {
            #expect(reason.contains("antenna statements") && reason.contains("unused"))
        }
    }

    private func fixture(_ scenario: String) async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore) {
        let support = ProcessGeometryTests()
        let (base, store) = try await support.fixtureSources()
        var request = support.nativeRequest(base)
        if scenario != "absent" {
            let assetID = scenario == "cell" ? "cells" : "tech"
            let old = try #require(request.processAssets[assetID])
            var text = String(decoding: try await store.read(old), as: UTF8.self)
            if ["mapped", "explicit", "model-only", "oxide"].contains(scenario) {
                let statements = scenario == "model-only" ? "ANTENNAMODEL OXIDE1 ;" : scenario == "oxide" ? "ANTENNAMODEL OXIDE2 ; ANTENNADIFFAREARATIO 2.5 ;" : scenario == "explicit" ? "ANTENNAMODEL OXIDE1 ; ANTENNADIFFAREARATIO 2.5 ;" : "ANTENNADIFFAREARATIO 2.5 ;"
                text = text.replacingOccurrences(of: "END metH", with: statements + " END metH")
            } else {
                let statement = scenario == "technology-only"
                    ? "ANTENNADIFFAREARATIO PWL ((0 3)(0.125 4.5)) ;" : "ANTENNAMODEL OXIDE2 ;"
                text = text.replacingOccurrences(of: "END LIBRARY", with: "LAYER unused TYPE CUT ; \(statement) END unused END LIBRARY")
            }
            let bytes = Data(text.utf8)
            let parsed = try LEFLibraryReader.read(bytes)
            #expect(parsed.layers.contains { !$0.antennaStatements.isEmpty })
            let replacement = try await store.registerInput(bytes, relativePath: "inputs/antenna-\(assetID).lef", kind: .technology, format: .lef)
            request.processAssets[assetID] = replacement
            let oldManifest = try request.requireBinding(for: request.pdk.manifest)
            var manifest = try PDKManifestCodec.decode(data: await store.read(oldManifest))
            let index = try #require(manifest.assets.firstIndex { $0.assetID == assetID })
            manifest.assets[index].sha256 = replacement.reference.digest.hexadecimalValue
            manifest.assets[index].byteCount = Int64(bytes.count)
            let binding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/antenna-process.json", kind: .technology, format: .json)
            request.pdk = try PDKReference(manifest: binding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: binding),
                processID: manifest.processID, version: manifest.version)
            request.inputBindings = [binding]
        } else {
            request.inputBindings = [try request.requireBinding(for: request.pdk.manifest)]
        }
        if scenario == "technology-only" {
            request.processAssets.removeValue(forKey: "cells")
            request.initialSnapshot?.cells = []
            request.initialSnapshot?.pins = []
        }
        let design = try await store.registerInput(Data("module fixture_top(); endmodule".utf8), relativePath: "inputs/antenna.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Antenna capability admission".utf8), relativePath: "inputs/antenna.sdc", kind: .constraint, format: .sdc)
        request.design.artifact = design.reference
        request.design.designDigest = design.reference.digest.hexadecimalValue
        request.constraints = constraints
        request.inputBindings += [design, constraints] + request.processAssets.values.sorted { $0.path < $1.path }
        request.inputs = request.inputBindings.map(\.reference)
        return (request, store)
    }

    private func invoke(_ request: PhysicalDesignRequest, root: URL) async throws -> PhysicalDesignResult {
        let source = root.appending(path: request.runID + ".json"), output = root.appending(path: request.runID + "-result.json")
        try PhysicalDesignJSONCodec().encode(request).write(to: source)
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { do { try handle.close() } catch { Issue.record(error) } }
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", source.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        let result = try PhysicalDesignJSONCodec().decode(PhysicalDesignResult.self, from: Data(contentsOf: output))
        #expect((process.terminationStatus == 0) == (result.status == .completed))
        return result
    }
}
