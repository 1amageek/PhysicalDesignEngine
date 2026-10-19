import CircuiteFoundation
import DEF
import Foundation
import LayoutIR
import MaskGeometry
import PDKCore
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Source layer routing widths", .timeLimit(.minutes(1)))
struct SourceRoutingWidthTests {
    @Test(arguments: ["source", "legacy", "uniform", "budget"])
    func actualAPIAndCLIPreserveWidthsOrRefuseAtomically(scenario: String) async throws {
        let fixture = try await fixture()
        var request = fixture.request
        if scenario == "legacy" { request.configuration.implementationConstraints?.sourceRoutingWidthPolicy = nil }
        if scenario == "uniform" { request.configuration.implementationConstraints?.sourceRoutingWidthPolicy = .uniform }
        if scenario == "budget" { request.configuration.maximumRoutingCandidateChecks = 1 }
        let failed = scenario != "source"
        let root = FileManager.default.temporaryDirectory.appending(path: "source-layer-width-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in request.inputBindings {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fixture.store.read(binding).write(to: url)
        }
        let codec = PhysicalDesignJSONCodec()
        let fileStore = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        for useCLI in [false, true] {
            request.runID = "source-width-\(scenario)-\(useCLI)"
            let result: PhysicalDesignResult
            if useCLI { result = try await cli(request, root: root) }
            else { result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request) }
            #expect(result.status == (failed ? .blocked : .completed), "\(result.diagnostics)")
            if failed {
                #expect(result.artifactBindings.isEmpty && result.payload.physicalDesign == nil)
                if scenario == "budget" { #expect(result.diagnostics.contains { $0.code.rawValue == "routing_candidate_budget_exhausted" }, "\(result.diagnostics)") }
                else { #expect(result.diagnostics.contains { $0.summary.contains("width") || $0.summary.contains("WIDTH") }, "\(result.diagnostics)") }
                continue
            }
            let store: any PhysicalDesignArtifactStore = useCLI ? fileStore : fixture.store
            let artifact = try #require(result.payload.physicalDesign?.layoutArtifact)
            let output = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(artifact))
            try verify(output, geometry: fixture.geometry)
            let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
            try verifyDEF(await store.read(def), snapshot: output, geometry: fixture.geometry)
            var resumed = PhysicalDesignRequest(runID: "source-width-resume-\(useCLI)", inputBindings: request.inputBindings + [artifact],
                design: request.design, constraints: request.constraints, requestedModeIDs: request.requestedModeIDs,
                pdk: request.pdk, inputLayout: result.payload.physicalDesign, stage: .timingECO,
                configuration: request.configuration, processAssets: request.processAssets)
            resumed.configuration.ecoAction = .rerouteNet; resumed.configuration.ecoTargetNetID = "N"
            let continued: PhysicalDesignResult
            if useCLI { continued = try await cli(resumed, root: root) }
            else { continued = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(resumed) }
            #expect(continued.status == .completed, "\(continued.diagnostics)")
            let reread = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(try #require(continued.payload.physicalDesign?.layoutArtifact)))
            try verify(reread, geometry: fixture.geometry)
            #expect(reread.routes == output.routes && reread.vias == output.vias)
            for binding in continued.artifactBindings { _ = try await store.read(binding) }
        }
    }

    @Test func narrowLayerAccessAtTheCoreEdgeRemainsInTheEventDomain() async throws {
        let fixture = try await fixture()
        var snapshot = try #require(fixture.request.initialSnapshot)
        snapshot.cells = []; snapshot.rows = []; snapshot.blockages = []
        let port = PhysicalDesignTopPort(rectangle: .init(x: 0, y: -50, width: 100, height: 100), layer: 2,
            placementX: 0, placementY: 100, orientation: .n, placementStatus: .placed, use: .signal)
        let target = PhysicalDesignTopPort(rectangle: .init(x: -50, y: -50, width: 100, height: 100), layer: 2,
            placementX: 1000, placementY: 100, orientation: .n, placementStatus: .placed, use: .signal)
        snapshot.pins = [.init(id: "edge", cellID: nil, name: "edge", x: 50, y: 100, netID: "N", direction: "input", accessLayer: 2, topPort: port),
            .init(id: "target", cellID: nil, name: "target", x: 1000, y: 100, netID: "N", direction: "output", accessLayer: 2, topPort: target)]
        snapshot.nets = [.init(id: "N", pinIDs: ["edge", "target"])]
        let result = try PhysicalDesignSourceRouter().route(snapshot, configuration: fixture.request.configuration,
            mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        #expect(result.snapshot.pins.first { $0.id == "edge" }?.x == 50)
        #expect(!result.snapshot.routes.isEmpty)
        for segment in result.snapshot.routes.flatMap(\.segments) {
            #expect(segment.widthDBU == (segment.layer == 2 ? 100 : 140))
            let footprint = try segment.qualifiedFootprint()
            #expect(footprint.x >= 0 && footprint.y >= 0 && footprint.maxX <= snapshot.core!.maxX && footprint.maxY <= snapshot.core!.maxY)
        }
    }

    @Test func layerWidthsShareTheExistingCumulativeBudgetAndCancellation() async throws {
        let fixture = try await fixture()
        let input = try #require(fixture.request.initialSnapshot)
        let router = PhysicalDesignSourceRouter()
        let measured = try router.route(input, configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        var configuration = fixture.request.configuration
        configuration.maximumRoutingCandidateChecks = measured.checks
        let exact = try router.route(input, configuration: configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        #expect(exact.checks == measured.checks && exact.snapshot.routes == measured.snapshot.routes && exact.snapshot.vias == measured.snapshot.vias)
        configuration.maximumRoutingCandidateChecks = measured.checks - 1
        do {
            _ = try router.route(input, configuration: configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
            Issue.record("Layer-specific widths reset or ignored the cumulative budget")
        } catch let error as PhysicalDesignSourceRouter.Failure { #expect(error.code == "routing_candidate_budget_exhausted") }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try router.route(input, configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        #expect(await task.value)
    }

    @Test(arguments: [false, true])
    func sourceDefaultSeparatesSelectedAndRetainedSpecialNets(selected: Bool) async throws {
        let fixture = try await fixture()
        var snapshot = try #require(fixture.request.initialSnapshot)
        if selected {
            snapshot.nets[0].routingClass = .special
            do {
                _ = try PhysicalDesignSourceRouter().route(snapshot, configuration: fixture.request.configuration,
                    mode: "global", onlyNetID: "N", geometry: fixture.geometry)
                Issue.record("Source-default policy selected explicit-width special mutation")
            } catch let error as PhysicalDesignSourceRouter.Failure {
                #expect(error.code == "routing_special_width_policy_unsupported")
            }
            #expect(snapshot.routes.isEmpty && snapshot.vias.isEmpty)
        } else {
            snapshot.nets.append(.init(id: "M", pinIDs: [], routingClass: .special))
            let retained = PhysicalDesignSnapshot.Route(id: "retained-special", netID: "M", segments: [
                .init(id: "special-wire", layer: 3, x1: 8100, y1: 7100, x2: 8100, y2: 7700,
                    widthDBU: 200, endpointExtensions: .init(beginDBU: 0, endDBU: 0))], defStatus: .routed)
            snapshot.routes = [retained]
            let routed = try PhysicalDesignSourceRouter().route(snapshot, configuration: fixture.request.configuration,
                mode: "global", onlyNetID: "N", geometry: fixture.geometry).snapshot
            #expect(routed.routes.first { $0.netID == "M" } == retained)
            #expect(routed.nets.first { $0.id == "M" } == snapshot.nets.last)
            #expect(Set(routed.routes.filter { $0.netID == "N" }.flatMap(\.segments).map(\.widthDBU)) == [100, 140])
        }
    }

    private func verify(_ snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws {
        try geometry.validate(snapshot)
        let segments = snapshot.routes.flatMap(\.segments)
        #expect(Set(segments.map(\.layer)) == [2, 3] && !snapshot.vias.isEmpty)
        for segment in segments {
            let width: Int64 = segment.layer == 2 ? 100 : 140
            #expect(segment.widthDBU == width && segment.endpointExtensions == .init(beginDBU: width / 2, endDBU: width / 2))
            _ = try segment.qualifiedFootprint()
        }
        for via in snapshot.vias { #expect(via.master == "hv") }
        #expect(snapshot.processManifest == geometry.manifestReference && snapshot.processAssets == geometry.sources)
    }

    private func verifyDEF(_ bytes: Data, snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws {
        let document = try DEFLibraryReader.read(bytes)
        let net = try #require(document.nets.first { $0.name == "N" })
        #expect(Set(net.connections.map { "\($0.componentName)/\($0.pinName)" }) == ["U1/Y", "U2/A"])
        var canonical: [Int16: Region] = [:], standard: [Int16: Region] = [:]
        func merge(_ region: Region, into regions: inout [Int16: Region]) throws {
            regions[region.layer] = try (regions[region.layer] ?? Region(layer: region.layer)).union(region)
        }
        for segment in snapshot.routes.flatMap(\.segments) {
            try merge(PhysicalDesignSourceRouter.conductor(segment, width: #require(segment.widthDBU)), into: &canonical)
        }
        for via in snapshot.vias {
            for shape in try geometry.viaShapes(master: #require(via.master), x: via.x, y: via.y) { try merge(Region(layer: shape.layer, polygons: [shape]), into: &canonical) }
        }
        for route in net.routing {
            let layer = try #require(geometry.layers.first { $0.value.name == route.layerName }?.key)
            if let name = route.viaName {
                #expect(route.points.count == 1)
                let point = try #require(route.points.first)
                for shape in try geometry.viaShapes(master: name, x: Int64(point.x), y: Int64(point.y)) { try merge(Region(layer: shape.layer, polygons: [shape]), into: &standard) }
            } else {
                #expect(route.points.count == 2 && route.pointExtensions.count == 2)
                let width = try geometry.routingWidthAndSpacing(layer: Int(layer), units: snapshot.unitsPerMicron, width: nil, areaHandledSeparately: true).width
                let a = route.points[0], b = route.points[1]
                let segment = PhysicalDesignSnapshot.RouteSegment(id: "standard", layer: Int(layer), x1: Int64(a.x), y1: Int64(a.y), x2: Int64(b.x), y2: Int64(b.y), widthDBU: width,
                    endpointExtensions: .init(beginDBU: Int64(try #require(route.pointExtensions[0])), endDBU: Int64(try #require(route.pointExtensions[1]))))
                try merge(PhysicalDesignSourceRouter.conductor(segment, width: width), into: &standard)
            }
        }
        #expect(Set(standard.keys) == Set(canonical.keys))
        for (layer, region) in canonical { #expect(try region.symmetricDifference(#require(standard[layer])).isEmpty) }
    }

    private func fixture() async throws -> (geometry: PhysicalDesignProcessGeometry, request: PhysicalDesignRequest, store: InMemoryPhysicalDesignArtifactStore) {
        let support = ProcessGeometryTests()
        let (base, store) = try await support.fixtureSources(routingPorts: true)
        let old = try #require(base.processAssets["tech"])
        let text = try #require(String(data: await store.read(old), encoding: .utf8))
        let source = text.replacingOccurrences(of: "DIRECTION VERTICAL ; PITCH 0.4 ; OFFSET 0.1 ; WIDTH 0.1", with: "DIRECTION VERTICAL ; PITCH 0.4 ; OFFSET 0.1 ; WIDTH 0.14")
        #expect(source != text)
        let binding = try await store.registerInput(Data(source.utf8), relativePath: "inputs/layer-width.lef", kind: .technology, format: .lef)
        var manifest = try PDKManifestCodec.decode(data: await store.read(try base.requireBinding(for: base.pdk.manifest)))
        let index = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[index].sha256 = binding.reference.digest.hexadecimalValue
        manifest.assets[index].byteCount = Int64(source.utf8.count); manifest.assets[index].path = "layer-width.lef"
        let manifestBinding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/layer-width-process.json", kind: .technology, format: .json)
        let design = try await store.registerInput(Data("module fixture_top(); wire N; INV_X1 U1(.Y(N)); INV_X1 U2(.A(N)); endmodule\n".utf8), relativePath: "inputs/layer-width.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Source-qualified geometry; no characterized timing claim.\n".utf8), relativePath: "inputs/layer-width.sdc", kind: .constraint, format: .sdc)
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
        prepared.configuration.implementationConstraints?.sourceRoutingWidthPolicy = .sourceDefault
        prepared = PhysicalDesignRequest(runID: "source-width-routing", inputBindings: [manifestBinding, design, constraints],
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

    private func cli(_ request: PhysicalDesignRequest, root: URL) async throws -> PhysicalDesignResult {
        let codec = PhysicalDesignJSONCodec(), requestURL = root.appending(path: "request.json"), resultURL = root.appending(path: "result.json")
        try codec.encode(request).write(to: requestURL)
        #expect(FileManager.default.createFile(atPath: resultURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: resultURL)
        defer { do { try handle.close() } catch { Issue.record(error) } }
        let process = Process(); process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", requestURL.path, "--project-root", root.path]; process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        let result = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: resultURL))
        #expect((process.terminationStatus == 0) == (result.status == .completed))
        return result
    }
}
