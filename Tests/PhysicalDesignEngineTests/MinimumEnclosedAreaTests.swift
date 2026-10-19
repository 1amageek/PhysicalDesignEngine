import Foundation
import DEF
import LEF
import LayoutIR
import MaskGeometry
import PDKCore
import PhysicalDesignEngine
import Testing
import Synchronization
@testable import PhysicalDesignCore

@Suite("Native minimum enclosed hole area", .timeLimit(.minutes(1)))
struct MinimumEnclosedAreaTests {
    @Test func mergedHoleBelowThresholdIsRejected() async throws {
        try await exercise("below")
    }

    @Test(arguments: ["equal", "solid", "empty", "mixed-owners", "port", "via", "obs", "blockage",
        "technology-only", "technology-solid", "technology-empty", "budget", "unmapped", "unknown-width", "output-below", "technology-no-site-below", "technology-no-site-solid", "technology-no-site-empty", "technology-no-site-instance", "technology-no-site-output-grid", "present-site-row"])
    func apiAndCLI(_ scenario: String) async throws { try await exercise(scenario) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEF_REAL_TECHLEF_DIRECTORY"] != nil))
    func originalMet1Met2Law() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["LEF_REAL_TECHLEF_DIRECTORY"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: directory).appending(path: "sky130_fd_sc_hd__nom.tlef"))
        let source = String(decoding: bytes, as: UTF8.self)
        var laws: [String: String] = [:]
        for name in ["met1", "met2"] {
            let start = try #require(source.range(of: "LAYER " + name + "\n"))
            let end = try #require(source.range(of: "END " + name, range: start.upperBound..<source.endIndex))
            let lines = source[start.lowerBound..<end.upperBound].split(separator: "\n")
                .filter { $0.contains("MINENCLOSEDAREA") }
            #expect(lines.count == 1)
            let line = String(try #require(lines.first))
            let selected = try LEFLibraryReader.read(Data("LAYER \(name) TYPE ROUTING ;\n\(line)\nEND \(name) END LIBRARY".utf8))
            #expect(selected.layers[0].minimumEnclosedAreas == [0.14])
            laws[name] = line
            Attachment.record(Array(Data(line.utf8)), named: "original-\(name)-hole-law.lef")
        }
        // Only the exact selected hole statements enter this fixture, not the full PDK rule set.
        try await exercise("below", laws: laws)
        try await exercise("equal", laws: laws)
    }

    @Test(arguments: ["ring", "open", "solid", "two-holes", "minimum-coordinate", "maximum-coordinate", "unsigned-area", "budget", "diagonal"])
    func exactBoundedHoleKernel(_ scenario: String) throws {
        let low: Int32 = scenario == "minimum-coordinate" || scenario == "unsigned-area" ? .min : 0
        let high: Int32 = scenario == "maximum-coordinate" || scenario == "unsigned-area" ? .max : low + 400
        let bottom: Int32 = scenario == "unsigned-area" ? .min : 0
        let top: Int32 = scenario == "unsigned-area" ? .max : 700
        let wall: Int32 = scenario == "unsigned-area" ? 1 : 100
        func box(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> IRBoundary {
            .init(layer: 2, datatype: 0, points: [.init(x: x0, y: y0), .init(x: x1, y: y0),
                .init(x: x1, y: y1), .init(x: x0, y: y1), .init(x: x0, y: y0)])
        }
        let left = scenario == "maximum-coordinate" ? high - 400 : low
        var polygons = [box(left, bottom, left + wall, top), box(high - wall, bottom, high, top),
            box(left, bottom, high, bottom + wall), box(left, top - wall, high, top)]
        if scenario == "open" { polygons.removeLast() }
        if scenario == "solid" { polygons.append(box(left, bottom, high, top)) }
        if scenario == "two-holes" { polygons.append(box(190, 100, 210, 600)) }
        if scenario == "diagonal" { polygons = [.init(layer: 2, datatype: 0, points: [.init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 50, y: 100), .init(x: 0, y: 0)])] }
        var budget = PhysicalDesignRoutingWorkBudget(caller: scenario == "budget" ? 1 : nil)
        if scenario == "budget" || scenario == "diagonal" {
            do {
                _ = try PhysicalDesignHoleAreaGeometry.areas(in: Region(layer: 2, polygons: polygons), budget: &budget)
                Issue.record("Invalid or over-budget hole geometry must fail.")
            } catch let error as PhysicalDesignSourceRouter.Failure {
                #expect(scenario == "budget" && error.code == "routing_candidate_budget_exhausted")
            } catch let error as PhysicalDesignRoutingSourceError {
                #expect(scenario == "diagonal" && error.code == "routing_spacing_geometry_invalid")
            }
            return
        }
        let actual = try PhysicalDesignHoleAreaGeometry.areas(in: Region(layer: 2, polygons: polygons), budget: &budget).sorted()
        let expected: [UInt64]
        switch scenario {
        case "open", "solid": expected = []
        case "two-holes": expected = [45000, 45000]
        case "unsigned-area": expected = [UInt64(Int64(Int32.max) - Int64(Int32.min) - 2) * UInt64(Int64(Int32.max) - Int64(Int32.min) - 2)]
        default: expected = [100000]
        }
        #expect(actual == expected)
        #expect(budget.checks > 0 && budget.remaining >= 0)
    }

    @Test func lowerDecompositionCancellationRemainsCancellation() throws {
        func box(_ x: Int32) -> IRBoundary {
            .init(layer: 2, datatype: 0, points: [.init(x: x, y: 0), .init(x: x + 100, y: 0),
                .init(x: x + 100, y: 700), .init(x: x, y: 700), .init(x: x, y: 0)])
        }
        let region = Region(layer: 2, polygons: [box(0), box(300)])
        let probes = Mutex(0)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        do {
            _ = try PhysicalDesignHoleAreaGeometry.areas(in: region, budget: &budget, additionalCancellationCheck: {
                probes.withLock { count in
                    count += 1
                    // The first five-point rectangle has emitted its band by probe 15.
                    return count == 20
                }
            })
            Issue.record("Lower decomposition cancellation must remain cancellation at Native admission.")
        } catch is CancellationError {
            #expect(probes.withLock { $0 } == 20)
            #expect(budget.checks > 0)
        }
    }

    @Test @MainActor func cancellationAndExactThreshold() async throws {
        #expect(try PhysicalDesignRoutingAreaRule(areaMicronsSquared: 0.14, unitsPerMicron: 1000).minimumDBU2 == 140000)
        #expect(throws: PhysicalDesignTechnologyError.self) { try PhysicalDesignRoutingAreaRule(areaMicronsSquared: 0.0000001, unitsPerMicron: 1000) }
        let task = Task {
            var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            return try PhysicalDesignHoleAreaGeometry.areas(in: Region(layer: 2), budget: &budget)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func exercise(_ scenario: String, laws: [String: String]? = nil) async throws {
        let (base, memory) = try await fixture(scenario, laws: laws)
        let root = FileManager.default.temporaryDirectory.appending(path: "minimum-hole-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in base.inputBindings {
            let path = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: path)
        }
        let failures = ["below", "mixed-owners", "port", "via", "technology-only", "budget", "unmapped", "unknown-width", "output-below", "technology-no-site-below", "technology-no-site-instance", "technology-no-site-output-grid", "present-site-row"]
        for cli in [false, true] {
            var request = base
            request.runID = "hole-\(scenario)-\(cli)"
            let store: any PhysicalDesignArtifactStore = cli ? FileSystemPhysicalDesignArtifactStore(projectRoot: root) : memory
            let codec = PhysicalDesignJSONCodec()
            request = try codec.decode(PhysicalDesignRequest.self, from: codec.encode(request))
            let result = cli ? try await invoke(request, root: root) : try await PhysicalDesignEngine(artifactStore: store).execute(request)
            #expect(result.provenance.producer.version == NativePhysicalDesignExecutor.currentImplementationVersion)
            let resultBytes = try codec.encode(result)
            Attachment.record(Array(resultBytes), named: request.runID + "-result.json")
            let saved = root.appending(path: request.runID + "-saved.json")
            try resultBytes.write(to: saved)
            let retained = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: saved))
            #expect(retained.status == result.status && retained.diagnostics == result.diagnostics)
            if failures.contains(scenario) {
                #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
                let cause: String
                switch scenario {
                case "budget": cause = "ceiling"
                case "unknown-width": cause = "qualified"
                case "technology-no-site-instance": cause = "Master"
                case "technology-no-site-output-grid": cause = "MANUFACTURINGGRID"
                case "present-site-row": cause = "Row"
                default: cause = "MINENCLOSEDAREA"
                }
                #expect(result.diagnostics.contains { $0.summary.contains(cause) }, "\(result.diagnostics)")
                let path = "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/revision.json"
                if cli { #expect(!FileManager.default.fileExists(atPath: root.appending(path: path).path)) }
                else { #expect(await memory.data(at: path) == nil) }
            } else {
                #expect(result.status == .completed, "\(result.diagnostics)")
                let reference = try #require(result.payload.physicalDesign)
                let snapshot = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
                #expect(snapshot.processManifest == request.pdk.manifest)
                #expect(snapshot.processAssets == request.processAssets.mapValues(\.reference))
                #expect(snapshot.fills == request.initialSnapshot?.fills)
                for binding in result.artifactBindings { _ = try await store.read(binding) }
                if scenario.contains("no-site") {
                    #expect(snapshot.cells.isEmpty && snapshot.rows.allSatisfy { $0.siteName == nil })
                    let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
                    let document = try DEFLibraryReader.read(await store.read(def))
                    #expect(document.rows.map(\.stepY) == snapshot.rows.map { Int32($0.height) })
                    #expect(try DEFLibraryReader.read(DEFLibraryWriter.write(document)) == document)
                }
                var resumed = request
                resumed.runID += "-resume"
                resumed.initialSnapshot = nil
                resumed.inputLayout = reference
                resumed.inputBindings.append(reference.layoutArtifact)
                resumed.inputs.append(reference.layoutArtifact.reference)
                let replay = cli ? try await invoke(resumed, root: root) : try await PhysicalDesignEngine(artifactStore: store).execute(resumed)
                #expect(replay.status == .completed, "\(replay.diagnostics)")
                let again = try #require(replay.payload.physicalDesign)
                let reloaded = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(again.layoutArtifact))
                #expect(reloaded.processAssets == snapshot.processAssets && reloaded.fills == snapshot.fills)
            }
        }
    }

    private func fixture(_ scenario: String, laws: [String: String]?) async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore) {
        let support = ProcessGeometryTests()
        let (base, store) = try await support.fixtureSources()
        var request = support.nativeRequest(base)
        request.initialSnapshot?.cells = []
        request.initialSnapshot?.pins = []
        request.initialSnapshot?.nets = [.init(id: "N", pinIDs: [], routingClass: .regular)]
        let height: Int64 = scenario == "equal" ? 900 : 700
        let ring: [PhysicalDesignSnapshot.Rect] = [
            .init(x: 3000, y: 3000, width: 100, height: height),
            .init(x: 3300, y: 3000, width: 100, height: height),
            .init(x: 3000, y: 3000, width: 400, height: 100),
            .init(x: 3000, y: 3000 + height - 100, width: 400, height: 100)
        ]
        // The union's empty interior is 200*(height-200); metal island area is different.
        #expect(UInt64(200 * (height - 200)) == (scenario == "equal" ? 140000 : 100000))
        request.initialSnapshot?.fills = ring.enumerated().map { .init(id: "F\($0.offset)", layer: 2, geometry: $0.element) }
        if ["solid", "technology-solid", "technology-no-site-solid"].contains(scenario) {
            request.initialSnapshot?.fills.append(.init(id: "center", layer: 2, geometry: .init(x: 3100, y: 3100, width: 200, height: 500)))
        }
        if ["empty", "technology-empty", "unmapped", "technology-no-site-empty", "technology-no-site-instance", "technology-no-site-output-grid"].contains(scenario) { request.initialSnapshot?.fills = [] }
        if scenario.hasPrefix("technology-") { request.processAssets.removeValue(forKey: "cells") }
        if scenario == "budget" { request.configuration.maximumRoutingCandidateChecks = 1 }
        if scenario == "mixed-owners" || scenario == "unknown-width" {
            request.initialSnapshot?.fills = [.init(id: "F3", layer: 2, geometry: ring[3])]
            request.initialSnapshot?.powerStructures = [.init(id: "PG", netID: "N", kind: "strap", layer: 2, geometry: ring[0])]
            request.initialSnapshot?.pins = [.init(id: "P", name: "P", x: 3300, y: 3000, netID: "N", direction: "INPUT", accessLayer: 2,
                topPort: .init(rectangle: ring[1], layer: 2, placementX: 0, placementY: 0, orientation: .n, placementStatus: .fixed, use: .signal))]
            request.initialSnapshot?.nets[0].pinIDs = ["P"]
            request.initialSnapshot?.routes = [.init(id: "R", netID: "N", segments: [.init(id: "S", layer: 2,
                x1: 3000, y1: 3050, x2: 3400, y2: 3050, widthDBU: scenario == "unknown-width" ? nil : 100,
                endpointExtensions: scenario == "unknown-width" ? nil : .init(beginDBU: 0, endDBU: 0))])]
        }
        var replacements: [String: Data] = [:]
        for asset in ["tech", "cells"] {
            let binding = try #require(base.processAssets[asset])
            var text = String(decoding: try await store.read(binding), as: UTF8.self)
                .replacingOccurrences(of: "metH", with: "met1").replacingOccurrences(of: "metV", with: "met2")
            if asset == "tech" {
                if scenario.contains("no-site") {
                    text = text.replacingOccurrences(of: "SITE unit CLASS CORE ; SIZE 0.1 BY 1 ; SYMMETRY X Y R90 ; END unit", with: "")
                }
                if scenario == "technology-no-site-output-grid" {
                    text = text.replacingOccurrences(of: "VERSION 5.8 ;", with: "VERSION 5.8 ; MANUFACTURINGGRID 0.005 ;")
                }
                for name in ["met1", "met2"] {
                    text = text.replacingOccurrences(of: "END " + name, with: (laws?[name] ?? "MINENCLOSEDAREA 0.14 ;") + "\nEND " + name)
                }
                if scenario == "unmapped" { text = text.replacingOccurrences(of: "END LIBRARY", with: "LAYER unused TYPE ROUTING ; MINENCLOSEDAREA 0.14 ; END unused END LIBRARY") }
                if scenario == "via" {
                    let rects = "RECT 0 0 0.1 0.7 ; RECT 0.3 0 0.4 0.7 ; RECT 0 0 0.4 0.1 ; RECT 0 0.6 0.4 0.7 ; RECT -0.05 -0.05 0.05 0.05 ;"
                    let start = try #require(text.range(of: "VIA hv DEFAULT"))
                    var via = String(text[start.lowerBound...])
                    via = via.replacingOccurrences(of: "LAYER met2 ; RECT -0.1 -0.1 0.1 0.1 ;", with: "LAYER met2 ; " + rects)
                    text = String(text[..<start.lowerBound]) + via
                    request.initialSnapshot?.fills = []
                    request.initialSnapshot?.vias = [.init(id: "V", netID: "N", x: 3000, y: 3000, lowerLayer: 2, upperLayer: 3, master: "hv")]
                }
            } else if scenario == "port" || scenario == "obs" || scenario == "output-below" {
                let rects = "RECT 0 0 0.1 0.7 ; RECT 0.3 0 0.4 0.7 ; RECT 0 0 0.4 0.1 ; RECT 0 0.6 0.4 0.7 ;"
                let addition = scenario == "port" ? "PIN HOLE DIRECTION INPUT ; USE SIGNAL ; PORT LAYER met1 ; \(rects) END END HOLE" : "OBS LAYER met1 ; \(rects) END"
                text = text.replacingOccurrences(of: "END INV_X1", with: (scenario == "output-below" ? "PIN SOLID DIRECTION INPUT ; USE SIGNAL ; PORT LAYER met1 ; RECT 0 0 2 1 ; END END SOLID" : addition) + "\nEND INV_X1")
                if scenario != "output-below" { request.initialSnapshot?.fills = [] }
                request.initialSnapshot?.cells = [.init(id: "U", master: "INV_X1", x: 3000, y: 3000, width: 2000, height: 1000)]
            }
            replacements[asset] = Data(text.utf8)
        }
        if scenario == "technology-no-site-instance" {
            request.initialSnapshot?.cells = [.init(id: "U", master: "INV_X1", x: 3000, y: 3000, width: 2000, height: 1000)]
        }
        if scenario == "technology-no-site-output-grid" {
            request.initialSnapshot?.core = nil
            request.configuration.coreMargin = 1
        }
        if scenario == "present-site-row" {
            request.initialSnapshot?.rows = [.init(id: "row", originX: 0, originY: 0, siteWidth: 100, height: 1000, siteCount: 100)]
        }
        if scenario == "output-below" {
            request.stage = .timingECO
            request.configuration.ecoAction = .moveCell
            request.configuration.ecoTargetCellID = "U"
            request.configuration.ecoDeltaX = 3000
            request.initialSnapshot?.cells[0].placed = true
            request.initialSnapshot?.rows = [.init(id: "row", originX: 0, originY: 3000, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit")]
        }
        if scenario == "blockage" { request.initialSnapshot?.blockages = ring; request.initialSnapshot?.fills = [] }
        var manifest = try PDKManifestCodec.decode(data: await store.read(try base.requireBinding(for: base.pdk.manifest)))
        for index in manifest.layers.indices {
            manifest.layers[index].name = manifest.layers[index].name.replacingOccurrences(of: "metH", with: "met1").replacingOccurrences(of: "metV", with: "met2")
        }
        for asset in request.processAssets.keys.sorted() {
            let data = try #require(replacements[asset])
            let binding = try await store.registerInput(data, relativePath: "inputs/hole-\(asset).lef", kind: .technology, format: .lef)
            request.processAssets[asset] = binding
            let index = try #require(manifest.assets.firstIndex { $0.assetID == asset })
            manifest.assets[index].sha256 = binding.reference.digest.hexadecimalValue
            manifest.assets[index].byteCount = Int64(data.count)
            if asset == "tech" { Attachment.record(Array(data), named: "selected-\(scenario)-tech.lef") }
        }
        let binding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/hole-process.json", kind: .technology, format: .json)
        request.pdk = try PDKReference(manifest: binding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: binding), processID: manifest.processID, version: manifest.version)
        let design = try await store.registerInput(Data("module fixture_top(); endmodule".utf8), relativePath: "inputs/hole.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Explicit hole geometry profile".utf8), relativePath: "inputs/hole.sdc", kind: .constraint, format: .sdc)
        request.design.artifact = design.reference
        request.design.designDigest = design.reference.digest.hexadecimalValue
        request.constraints = constraints
        request.inputBindings = [binding, design, constraints] + request.processAssets.values.sorted { $0.path < $1.path }
        request.inputs = request.inputBindings.map(\.reference)
        return (request, store)
    }

    private func invoke(_ request: PhysicalDesignRequest, root: URL) async throws -> PhysicalDesignResult {
        let source = root.appending(path: request.runID + ".json"), output = root.appending(path: request.runID + "-stdout.json")
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
