import Foundation
import Testing
import DEF
import CircuiteFoundation
import LayoutIR
import MaskGeometry
import PhysicalDesignEngine
@testable import PhysicalDesignCore

@Suite("Stage III retained physical geometry", .timeLimit(.minutes(2)))
struct StageIIIPhysicalGeometryTests {
    @Test("fill observes actual metal, source clearance and per-window density; DEF retains every rectangle", arguments: ["valid", "route", "window", "budget", "layer-spacing", "layer-spacing-valid"])
    func fillGeometry(_ scenario: String) async throws {
        let (geometry, base, store) = try await ProcessGeometryTests().fixture(scenario.hasPrefix("layer-spacing") ? "fill-layer-spacing" : "valid")
        var request = try await prepared(base, store: store, stage: .fillInsertion, routeSpacing: scenario.hasPrefix("layer-spacing") ? 300 : 100)
        let segment = PhysicalDesignSnapshot.RouteSegment(id: "metal", layer: 2, x1: 1000, y1: 500, x2: 9000, y2: 500,
            widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))
        request.initialSnapshot?.routes = [.init(id: "wire", netID: "N", segments: [segment])]
        if scenario == "route" { request.initialSnapshot?.fills = [.init(id: "existing", layer: 2, geometry: .init(x: 2000, y: 400, width: 500, height: 500))] }
        if scenario == "window" { request.initialSnapshot?.fills = [.init(id: "existing", layer: 2, geometry: .init(x: 6000, y: 2100, width: 1900, height: 1900))] }
        if scenario.hasPrefix("layer-spacing") {
            request.initialSnapshot?.fills = [.init(id: "one", layer: 3, geometry: .init(x: 1000, y: 2100, width: 100, height: 100)),
                .init(id: "two", layer: 3, geometry: .init(x: scenario == "layer-spacing" ? 1200 : 1400, y: 2100, width: 100, height: 100))]
        }
        if scenario == "budget" { request.configuration.repairConstraints?.maximumGeometryChecks = 1 }
        #expect(request.configuration.validationDiagnostics().isEmpty)
        #expect(request.initialSnapshot?.validationDiagnostics().isEmpty == true)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        if scenario != "valid" && scenario != "layer-spacing-valid" {
            #expect(result.status == .blocked && result.artifactBindings.isEmpty)
            let expectedCode = scenario == "budget" ? "fill_geometry_admission_failed" : "existing_fill_invalid"
            #expect(result.diagnostics.contains { $0.code.rawValue == expectedCode }, "\(result.diagnostics)")
            #expect(await store.data(at: "runs/\(request.runID)/physical-design/fill_insertion/revision.json") == nil)
            return
        }
        #expect(result.status == .completed, "\(result.diagnostics)")
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        #expect(!output.fills.isEmpty)
        var admission = try PhysicalDesignFillAdmission(snapshot: request.initialSnapshot!, configuration: request.configuration, geometry: geometry)
        for (index, fill) in output.fills.enumerated() {
            #expect(try admission.accepts(fill, existing: output.fills.enumerated().filter { $0.offset != index }.map(\.element)))
            #expect(try PhysicalDesignSourceRouter.rectangle(fill.geometry, layer: fill.layer).intersection(PhysicalDesignSourceRouter.conductor(segment, width: 100)).isEmpty)
        }
        let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        let standard = try DEFLibraryReader.read(await store.read(def))
        #expect(standard.fills.count == output.fills.count)
        #expect(standard.fills.allSatisfy { $0.rects.count == 1 })
        for (standardFill, fill) in zip(standard.fills, output.fills.sorted(by: { $0.id < $1.id })) {
            #expect(standardFill.layerName == geometry.sourceLayers[Int16(fill.layer)]?.name)
            #expect(Int64(standardFill.rects[0].x1) == fill.geometry.x && Int64(standardFill.rects[0].y1) == fill.geometry.y)
            #expect(Int64(standardFill.rects[0].x2) == fill.geometry.maxX && Int64(standardFill.rects[0].y2) == fill.geometry.maxY)
        }
    }

    @Test("redundant fixed contact must join actual same-net metal on both layers", arguments: [true, false])
    func redundantContact(_ bothLayers: Bool) async throws {
        let (_, base, store) = try await ProcessGeometryTests().fixture()
        var request = try await prepared(base, store: store, stage: .redundantViaInsertion)
        let h = PhysicalDesignSnapshot.RouteSegment(id: "h", layer: 2, x1: 1000, y1: 2500, x2: 9000, y2: 2500,
            widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))
        let v = PhysicalDesignSnapshot.RouteSegment(id: "v", layer: 3, x1: 4900, y1: 1000, x2: 4900, y2: 4500,
            widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))
        request.initialSnapshot?.routes = [.init(id: "wire", netID: "N", segments: bothLayers ? [h, v] : [h])]
        request.initialSnapshot?.vias = [.init(id: "original", netID: "N", x: 4900, y: 2500, lowerLayer: 2, upperLayer: 3, master: "hv")]
        #expect(request.configuration.validationDiagnostics().isEmpty)
        #expect(request.initialSnapshot?.validationDiagnostics().isEmpty == true)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        if !bothLayers {
            #expect(result.status == .blocked && result.artifactBindings.isEmpty)
            #expect(result.diagnostics.contains { $0.code.rawValue == "redundant_via_location_unavailable" }, "\(result.diagnostics)")
            return
        }
        #expect(result.status == .completed, "\(result.diagnostics)")
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        let inserted = try #require(output.vias.first { $0.isRedundant })
        let (geometry, _, _) = try await ProcessGeometryTests().fixture()
        var checks = 0
        #expect(try geometry.redundantContactConnected(inserted, snapshot: output, checks: &checks, maximumChecks: nil))
        #expect(output.routes == request.initialSnapshot?.routes)
    }

    @Test("a conflicting second artifact cannot leave an orphan first revision")
    func atomicStagePublication() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let request = PhysicalDesignFixtureFactory.request(stage: .floorplan, snapshot: PhysicalDesignFixtureFactory.snapshot())
        let prefix = "runs/\(request.runID)/physical-design/floorplan/"
        _ = try await store.registerInput(Data("immutable unrelated bytes".utf8), relativePath: prefix + "revision.def", kind: .layout, format: .def)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .failed && result.artifactBindings.isEmpty)
        #expect(await store.data(at: prefix + "revision.json") == nil)
        #expect(await store.data(at: prefix + "design-diff.json") == nil)
        #expect(await store.data(at: prefix + "run-manifest.json") == nil)
        #expect(await store.data(at: prefix + "revision.def") == Data("immutable unrelated bytes".utf8))
    }

    @Test("actual executable preserves fill output or refuses its finite budget", arguments: [false, true])
    func actualFillCLI(_ exhausted: Bool) async throws {
        let (_, base, memory) = try await ProcessGeometryTests().fixture()
        var request = try await prepared(base, store: memory, stage: .fillInsertion)
        if exhausted { request.configuration.repairConstraints?.maximumGeometryChecks = 1 }
        let evidenceRoot = ProcessInfo.processInfo.environment["LSI_PHYSICAL_S3_EVIDENCE_ROOT"]
        let root = evidenceRoot.map { URL(fileURLWithPath: $0).appending(path: "fill-cli-\(exhausted ? "budget" : "valid")") }
            ?? FileManager.default.temporaryDirectory.appending(path: "stageIII-fill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if evidenceRoot == nil { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } } }
        for binding in request.inputBindings {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: url)
        }
        let path = root.appending(path: "request.json")
        try PhysicalDesignJSONCodec().encode(request).write(to: path)
        let process = Process(); process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", path.path, "--project-root", root.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try bytes.write(to: root.appending(path: "cli-result.json"))
        try JSONSerialization.data(withJSONObject: ["executable": process.executableURL!.path, "arguments": process.arguments!, "exit": process.terminationStatus], options: [.prettyPrinted, .sortedKeys]).write(to: root.appending(path: "cli-command.json"))
        let result = try PhysicalDesignJSONCodec().decode(PhysicalDesignResult.self, from: bytes)
        if exhausted {
            #expect(process.terminationStatus != 0 && result.status == .blocked && result.artifactBindings.isEmpty)
            #expect(result.diagnostics.contains { $0.code.rawValue == "fill_geometry_admission_failed" }, "\(result.diagnostics)")
        } else {
            #expect(process.terminationStatus == 0 && result.status == .completed, "\(result.diagnostics)")
            let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
            let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
            let def = try DEFLibraryReader.read(await store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })))
            #expect(!snapshot.fills.isEmpty && def.fills.count == snapshot.fills.count)
            for binding in result.artifactBindings { _ = try await store.read(binding) }
        }
    }

    private func prepared(_ base: PhysicalDesignRequest, store: InMemoryPhysicalDesignArtifactStore, stage: PhysicalDesignStage, routeSpacing: Int64 = 100) async throws -> PhysicalDesignRequest {
        var request = base; request.stage = stage; request.runID = "stageIII-\(stage.rawValue)"
        request.configuration = .init(dieWidth: 10000, dieHeight: 5000, coreMargin: 0, rowHeight: 1000, siteWidth: 100,
            preferredRoutingLayers: [2, 3], maximumRoutingLayer: 3, powerNetNames: ["VDD"], fillWindowSize: 2000, fillSpacing: 100,
            implementationConstraints: .init(routeWidth: 100, routeSpacing: routeSpacing))
        request.configuration.repairConstraints = .init(minimumViaSpacing: 100, minimumFillSpacing: 100)
        request.initialSnapshot = .init(topCell: base.design.topDesignName, unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 10000, height: 5000), core: .init(x: 0, y: 0, width: 10000, height: 5000),
            rows: [.init(id: "row", originX: 0, originY: 0, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit")],
            nets: [.init(id: "N", pinIDs: [])])
        let design = try await store.registerInput(try PhysicalDesignJSONCodec().encode(request.initialSnapshot), relativePath: "inputs/stageIII-design.json", kind: .netlist, format: .json)
        let constraints = try await store.registerInput(Data("# Explicit geometry-only repair profile\n".utf8), relativePath: "inputs/stageIII.sdc", kind: .constraint, format: .sdc)
        var prepared = PhysicalDesignRequest(runID: request.runID, inputBindings: base.inputBindings.filter { $0.reference == base.pdk.manifest } + [design, constraints],
            design: .init(artifact: design.reference, topDesignName: base.design.topDesignName, designDigest: design.reference.digest.hexadecimalValue),
            constraints: constraints, requestedModeIDs: base.requestedModeIDs, pdk: base.pdk, stage: stage,
            configuration: request.configuration, initialSnapshot: request.initialSnapshot, processAssets: base.processAssets)
        #expect(prepared.configuration.validationDiagnostics().isEmpty)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: prepared, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: prepared, units: 1000)
        let bound = try geometry.bind(try #require(prepared.initialSnapshot))
        prepared.initialSnapshot = try PhysicalDesignTechnologyConstraints.prepare(bound, request: prepared, processInputs: inputs)
        try geometry.validate(try #require(prepared.initialSnapshot))
        #expect(geometry.sites["unit"]?.width == 100 && geometry.sites["unit"]?.height == 1000)
        #expect(geometry.sourceLayers[2]?.width == 0.1 && geometry.sourceLayers[2]?.spacing == 0.1)
        #expect(geometry.sourceLayers[3]?.width == 0.1 && geometry.sourceLayers[3]?.spacing == Double(routeSpacing) / 1000)
        return prepared
    }
}
