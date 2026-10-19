import Foundation
import LEF
import PDKCore
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Exact qualified fixed-contact enclosure", .timeLimit(.minutes(1)))
struct QualifiedEnclosureTests {
    @Test(arguments: ["directional", "wrong-side", "alternative-first", "alternative-last", "alternative-failure",
        "rotated", "independent-sides", "disjoint-metal", "all-cuts", "legacy", "negative", "unmapped",
        "wrong-order", "incomplete-order", "technology-only", "vacuous", "nonrectangular", "nonrectangular-alternative", "technology-only-hole-valid", "technology-only-hole-invalid"])
    func apiAndCLI(_ scenario: String) async throws {
        try await exercise(scenario)
    }

    @Test(arguments: ["technology-only-width-source", "technology-only-width-uniform"])
    func technologyOnlySourceWidthGeometry(_ scenario: String) async throws {
        try await exercise(scenario)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEF_REAL_TECHLEF_DIRECTORY"] != nil))
    func actualMconSourceLaw() async throws {
        try await exercise("real-mcon")
    }

    private func exercise(_ scenario: String) async throws {
        let (base, memory) = try await fixture(scenario)
        let root = FileManager.default.temporaryDirectory.appending(path: "qualified-enclosure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in base.inputBindings {
            let target = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: target)
        }
        let successful = ["directional", "alternative-first", "alternative-last", "rotated", "independent-sides",
            "legacy", "vacuous", "nonrectangular-alternative", "real-mcon", "technology-only-hole-valid", "technology-only-width-source"].contains(scenario)
        for cli in [false, true] {
            var request = base; request.runID = "enclosure-\(scenario)-\(cli)"
            let store: any PhysicalDesignArtifactStore = cli ? FileSystemPhysicalDesignArtifactStore(projectRoot: root) : memory
            let result = try await run(request, cli: cli, root: root, memory: memory)
            #expect(result.provenance.producer.version == NativePhysicalDesignExecutor.currentImplementationVersion)
            Attachment.record(Array(try PhysicalDesignJSONCodec().encode(result)), named: request.runID + "-result.json")
            if !successful {
                #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
                let unsupported = ["negative", "unmapped", "technology-only", "nonrectangular", "technology-only-width-uniform"].contains(scenario)
                #expect(result.diagnostics.contains { $0.code.rawValue == (unsupported ? "physical_technology_unsupported" : "physical_technology_invalid") }, "\(result.diagnostics)")
                let revision = "runs/\(request.runID)/physical-design/floorplan/revision.json"
                if cli { #expect(!FileManager.default.fileExists(atPath: root.appending(path: revision).path)) }
                else { #expect(await memory.data(at: revision) == nil) }
                continue
            }
            #expect(result.status == .completed, "\(result.diagnostics)")
            let reference = try #require(result.payload.physicalDesign)
            let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
            if scenario != "vacuous" {
                #expect(snapshot.processAssets == request.processAssets.mapValues(\.reference))
                let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
                let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: snapshot.unitsPerMicron)
                #expect(geometry.vias["hv"]?.shapes.filter { $0.layer == 4 }.isEmpty == false)
                if scenario == "technology-only-hole-valid" {
                    #expect(inputs.requiresSourceGeometry && inputs.cellViews.isEmpty)
                    #expect(geometry.minimumHoleAreas == [2: 140000, 3: 140000])
                    #expect(snapshot.vias.count == 1 && snapshot.vias[0].master == "hv")
                }
                if scenario == "technology-only-width-source" {
                    #expect(inputs.cellViews.isEmpty && !inputs.requiresSourceGeometry && inputs.requiresSourceGeometry(for: request))
                    #expect(geometry.minimumHoleAreas.isEmpty && snapshot.vias.first?.master == "hv")
                    for layer in [2, 3] {
                        #expect(try geometry.routingWidthAndSpacing(layer: layer, units: 1000, width: nil).width == 100)
                    }
                }
                try geometry.validate(snapshot)
            }
            for artifact in result.artifactBindings { _ = try await store.read(artifact) }
            if scenario == "directional" || scenario == "real-mcon" || scenario == "technology-only-hole-valid" || scenario == "technology-only-width-source" {
                var resumed = request; resumed.runID += "-resume"; resumed.initialSnapshot = nil; resumed.inputLayout = reference
                resumed.inputBindings.append(reference.layoutArtifact); resumed.inputs.append(reference.layoutArtifact.reference)
                let replay = try await run(resumed, cli: cli, root: root, memory: memory)
                #expect(replay.status == .completed, "\(replay.diagnostics)")
                let retained = try #require(replay.payload.physicalDesign)
                let saved = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(retained.layoutArtifact))
                #expect(saved.processAssets == snapshot.processAssets && saved.processManifest == snapshot.processManifest)
            }
        }
    }

    private func fixture(_ scenario: String) async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore) {
        let support = ProcessGeometryTests(); let (base, store) = try await support.fixtureSources()
        var request = support.nativeRequest(base)
        let old = try #require(request.processAssets["tech"])
        var text = String(decoding: try await store.read(old), as: UTF8.self)
        var rules = "ENCLOSURE BELOW 0 0 ; ENCLOSURE ABOVE 0.03 0.06 ;"
        var lower = "RECT -0.025 -0.025 0.025 0.025 ;"
        var upper = "RECT -0.055 -0.085 0.055 0.085 ;"
        var cuts = "RECT -0.025 -0.025 0.025 0.025 ;"
        switch scenario {
        case "wrong-side", "technology-only", "technology-only-hole-invalid": swap(&lower, &upper)
        case "alternative-first": rules = "ENCLOSURE BELOW 0 0 ; ENCLOSURE ABOVE 0.2 0.2 ; ENCLOSURE ABOVE 0.03 0.06 ;"
        case "alternative-last": rules += " ENCLOSURE ABOVE 0.2 0.2 ;"
        case "alternative-failure": rules = "ENCLOSURE BELOW 0 0 ; ENCLOSURE ABOVE 0.2 0.2 ; ENCLOSURE ABOVE 0.1 0.1 ;"
        case "rotated": upper = "RECT -0.085 -0.055 0.085 0.055 ;"
        case "independent-sides": rules = "ENCLOSURE BELOW 0.06 0.03 ; ENCLOSURE ABOVE 0.03 0.06 ;"; lower = "RECT -0.085 -0.055 0.085 0.055 ;"
        case "disjoint-metal": upper = "RECT -0.055 -0.085 0.025 0.085 ; RECT 0.035 -0.085 0.055 0.085 ;"
        case "all-cuts": cuts += " RECT 0.225 -0.025 0.275 0.025 ;"; lower = "RECT -0.025 -0.025 0.275 0.025 ;"
        case "legacy": rules = "ENCLOSURE 0.075 0.025 ;"; lower = "RECT -0.1 -0.05 0.1 0.05 ;"; upper = "RECT -0.05 -0.1 0.05 0.1 ;"
        case "negative": rules = "ENCLOSURE BELOW -0.01 0.03 ; ENCLOSURE ABOVE 0.03 0.06 ;"
        case "unmapped": text = text.replacingOccurrences(of: "END LIBRARY", with: "LAYER unused TYPE CUT ; ENCLOSURE ABOVE 0.03 0.06 ; END unused END LIBRARY")
        case "nonrectangular", "nonrectangular-alternative":
            cuts = "POLYGON -0.025 -0.025 0.025 -0.025 0.025 0 0 0 0 0.025 -0.025 0.025 ;"
            text = text.replacingOccurrences(of: "WIDTH 0.05 ; SPACING", with: "WIDTH 0.01 ; SPACING")
            if scenario == "nonrectangular-alternative" { rules += " ENCLOSURE ABOVE 0 0 ;" }
        case "real-mcon":
            let directory = try #require(ProcessInfo.processInfo.environment["LEF_REAL_TECHLEF_DIRECTORY"])
            let original = try Data(contentsOf: URL(filePath: directory).appending(path: "sky130_fd_sc_hd__nom.tlef"))
            let source = String(decoding: original, as: UTF8.self)
            let start = try #require(source.range(of: "LAYER mcon")), end = try #require(source.range(of: "  RESISTANCE", range: start.upperBound..<source.endIndex))
            let raw = String(source[start.lowerBound..<end.lowerBound])
            let document = try LEFLibraryReader.read(Data((raw + "END mcon\nEND LIBRARY\n").utf8))
            let layer = try #require(document.layers.first)
            #expect(layer.enclosures.count == 2 && layer.enclosures[0].side == .below && layer.enclosures[1].side == .above)
            #expect(layer.enclosures[0].overhang1 == 0 && layer.enclosures[0].overhang2 == 0)
            #expect(layer.enclosures[1].overhang1 == 0.03 && layer.enclosures[1].overhang2 == 0.06)
            text = text.replacingOccurrences(of: "LAYER cutHV TYPE CUT ; WIDTH 0.05 ; SPACING 0.05 ; END cutHV", with: raw + "END mcon")
            text = text.replacingOccurrences(of: "cutHV", with: "mcon")
            rules = ""; lower = "RECT -0.085 -0.085 0.085 0.085 ;"; cuts = lower; upper = "RECT -0.115 -0.145 0.115 0.145 ;"
            Attachment.record(Array(original), named: "original-nom.tlef")
            Attachment.record(Array(Data(raw.utf8)), named: "original-mcon-prefix.lef")
        default: break
        }
        text = text.replacingOccurrences(of: "END cutHV", with: rules + " END cutHV")
        text = text.replacingOccurrences(of: "LAYER metH ; RECT -0.1 -0.1 0.1 0.1 ;", with: "LAYER metH ; " + lower)
        text = text.replacingOccurrences(of: "LAYER metV ; RECT -0.1 -0.1 0.1 0.1 ;", with: "LAYER metV ; " + upper)
        text = text.replacingOccurrences(of: "RECT -0.025 -0.025 0.025 0.025 ;", with: cuts)
        if scenario == "wrong-order" {
            let a = "LAYER metH TYPE ROUTING ; DIRECTION HORIZONTAL ; PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ; END metH"
            let b = "LAYER metV TYPE ROUTING ; DIRECTION VERTICAL ; PITCH 0.4 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ; END metV"
            text = text.replacingOccurrences(of: a, with: "STACK_PLACEHOLDER").replacingOccurrences(of: b, with: a).replacingOccurrences(of: "STACK_PLACEHOLDER", with: b)
        }
        if scenario == "incomplete-order" { text = text.replacingOccurrences(of: "LAYER metH TYPE ROUTING ; DIRECTION HORIZONTAL ; PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ; END metH", with: "") }
        if scenario == "vacuous", let start = text.range(of: "VIA hv DEFAULT"), let end = text.range(of: "END hv", range: start.upperBound..<text.endIndex) { text.removeSubrange(start.lowerBound..<end.upperBound) }
        if scenario.hasPrefix("technology-only-hole-") {
            text = text.replacingOccurrences(of: "TYPE ROUTING ;", with: "TYPE ROUTING ; MINENCLOSEDAREA 0.14 ;")
        }
        let bytes = Data(text.utf8)
        let technology = try await store.registerInput(bytes, relativePath: "inputs/enclosure.lef", kind: .technology, format: .lef)
        let oldManifest = try request.requireBinding(for: request.pdk.manifest)
        var manifest = try PDKManifestCodec.decode(data: await store.read(oldManifest))
        let index = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[index].sha256 = technology.reference.digest.hexadecimalValue; manifest.assets[index].byteCount = Int64(bytes.count)
        if scenario == "real-mcon" { let cut = try #require(manifest.layers.firstIndex { $0.layerID == "C" }); manifest.layers[cut].name = "mcon" }
        let binding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/enclosure-process.json", kind: .technology, format: .json)
        request.pdk = try PDKReference(manifest: binding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: binding), processID: manifest.processID, version: manifest.version)
        request.processAssets["tech"] = technology
        if scenario.hasPrefix("technology-only") || scenario == "vacuous" { request.processAssets.removeValue(forKey: "cells"); request.initialSnapshot?.cells = []; request.initialSnapshot?.pins = [] }
        if scenario.hasPrefix("technology-only-hole-") {
            request.initialSnapshot?.nets = [.init(id: "N", pinIDs: [])]
            request.initialSnapshot?.vias = [.init(id: "V", netID: "N", x: 3000, y: 3000, lowerLayer: 2, upperLayer: 3, master: "hv")]
        }
        if scenario.hasPrefix("technology-only-width-") {
            var policy = request.configuration.implementationConstraints ?? .default
            policy.sourceRoutingWidthPolicy = scenario == "technology-only-width-source" ? .sourceDefault : .uniform
            request.configuration.implementationConstraints = policy
            request.initialSnapshot?.nets = [.init(id: "N", pinIDs: [])]
            request.initialSnapshot?.vias = [.init(id: "V", netID: "N", x: 3000, y: 3000, lowerLayer: 2, upperLayer: 3, master: "hv")]
        }
        let design = try await store.registerInput(Data("module fixture_top(); endmodule".utf8), relativePath: "inputs/enclosure.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Exact enclosure application".utf8), relativePath: "inputs/enclosure.sdc", kind: .constraint, format: .sdc)
        request.design.artifact = design.reference; request.design.designDigest = design.reference.digest.hexadecimalValue; request.constraints = constraints
        request.inputBindings = [binding, design, constraints] + request.processAssets.values.sorted { $0.path < $1.path }; request.inputs = request.inputBindings.map(\.reference)
        Attachment.record(Array(bytes), named: scenario + "-selected-tech.lef")
        return (request, store)
    }

    private func run(_ request: PhysicalDesignRequest, cli: Bool, root: URL,
        memory: InMemoryPhysicalDesignArtifactStore) async throws -> PhysicalDesignResult {
        if !cli { return try await PhysicalDesignEngine(artifactStore: memory).execute(request) }
        let source = root.appending(path: request.runID + ".json"), output = root.appending(path: request.runID + "-result.json")
        try PhysicalDesignJSONCodec().encode(request).write(to: source)
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { do { try handle.close() } catch { Issue.record(error) } }
        let process = Process(); process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", source.path, "--project-root", root.path]; process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        let result = try PhysicalDesignJSONCodec().decode(PhysicalDesignResult.self, from: Data(contentsOf: output))
        #expect((process.terminationStatus == 0) == (result.status == .completed))
        return result
    }
}
