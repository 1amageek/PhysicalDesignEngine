import Foundation
import LEF
import PDKCore
import Testing
@testable import PhysicalDesignCore

@Suite("Checked routing source adoption", .timeLimit(.minutes(1)))
struct RoutingSourceAdoptionTests {
    @Test func explicitRevisionPreservesParentAndAddsSourceTracks() async throws {
        let fixture = try await fixture()
        let adopter: any PhysicalDesignRoutingSourceAdopting = NativePhysicalDesignRoutingSourceAdopter()
        let result = try await adopter.adopt(fixture.input, store: fixture.store)
        let before = fixture.parent, after = result.snapshot
        #expect(after.cells == before.cells && after.pins == before.pins && after.nets == before.nets)
        #expect(after.routes == before.routes && after.vias == before.vias && after.clockTrees == before.clockTrees)
        let oldTracks = before.implementationState?.tracks ?? []
        #expect(Array((after.implementationState?.tracks ?? []).prefix(oldTracks.count)) == oldTracks)
        let newTrack = try #require(after.implementationState?.tracks.first { $0.layer == 6 })
        #expect(newTrack.direction == "horizontal" && newTrack.origin == 300 && newTrack.spacing == 600 && newTrack.count == 3)
        #expect(after.processManifest == fixture.input.newRequest.pdk.manifest)
        #expect(after.processAssets == fixture.input.newRequest.processAssets.mapValues { $0.reference })
        #expect(after.implementationState?.routingEvidence == nil)
        #expect(after.metadata["clockTimingStatus"] == "invalidated_by_routing_source_adoption")
        #expect(result.lineage.parent == fixture.input.parent)
        #expect(Set(result.lineage.addedLayerIDs) == ["X", "VX"])
        let codec = PhysicalDesignJSONCodec()
        let encoded = try #require(after.metadata["routingSourceAdoptionLineage"])
        #expect(try codec.decode(PhysicalDesignRoutingSourceAdoptionLineage.self, from: Data(encoded.utf8)) == result.lineage)
        #expect(try codec.decode(PhysicalDesignSnapshot.self, from: codec.encode(after)) == after)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: fixture.input.newRequest, store: fixture.store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: fixture.input.newRequest, units: 1000)
        try geometry.validate(after)
        // Ordinary resume still refuses the old source binding and technology identity.
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.bind(before) }
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try PhysicalDesignTechnologyConstraints.prepare(before, request: fixture.input.newRequest,
                processInputs: inputs, processGeometry: geometry)
        }
        #expect(try await fixture.store.read(fixture.input.parent.layoutArtifact) == fixture.parentBytes)
    }

    @Test(arguments: ["width", "cell", "collision", "grid", "generated"])
    func changedOrUnsupportedSourceCannotCreateRevision(_ scenario: String) async throws {
        let fixture = try await fixture(scenario)
        do {
            _ = try await NativePhysicalDesignRoutingSourceAdopter().adopt(fixture.input, store: fixture.store)
            Issue.record("An incompatible source created a checked revision.")
        } catch let error as PhysicalDesignRoutingSourceAdoptionError {
            let expected: PhysicalDesignRoutingSourceAdoptionError.Reason
            switch scenario {
            case "width": expected = .changedFacts
            case "cell": expected = .sourceMismatch
            case "collision": expected = .layerCollision
            case "generated": expected = .unsupported
            default: expected = .sourceValidation
            }
            #expect(error.reason == expected)
            if scenario == "grid" || scenario == "generated" { #expect(error.underlyingCause != nil) }
        }
        #expect(try await fixture.store.read(fixture.input.parent.layoutArtifact) == fixture.parentBytes)
    }

    @Test func foreignParentAndCallerLimitsRemainFailures() async throws {
        let fixture = try await fixture()
        var foreign = fixture.input.parent; foreign.topCell = "foreign"
        let input = PhysicalDesignRoutingSourceAdoptionInput(parent: foreign, oldRequest: fixture.input.oldRequest,
            newRequest: fixture.input.newRequest, limits: fixture.input.limits)
        do {
            _ = try await NativePhysicalDesignRoutingSourceAdopter().adopt(input, store: fixture.store)
            Issue.record("A foreign parent received a checked revision.")
        } catch let error as PhysicalDesignRoutingSourceAdoptionError { #expect(error.reason == .parentMismatch) }
        let limited = PhysicalDesignRoutingSourceAdoptionInput(parent: fixture.input.parent, oldRequest: fixture.input.oldRequest,
            newRequest: fixture.input.newRequest, limits: .init(maximumCombinedInputBytes: 1, maximumSourceAssets: 2, maximumSourceEntries: 1))
        do {
            _ = try await NativePhysicalDesignRoutingSourceAdopter().adopt(limited, store: fixture.store)
            Issue.record("Adoption exceeded its explicit logical allowance.")
        } catch let error as PhysicalDesignRoutingSourceAdoptionError { #expect(error.reason == .limitsExceeded) }
    }

    @Test func cancellationDoesNotBecomeSourceInvalidity() async throws {
        let fixture = try await fixture()
        let task = Task {
            _ = try await NativePhysicalDesignRoutingSourceAdopter().adopt(fixture.input, store: fixture.store)
        }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled adoption returned a revision.") }
        catch is CancellationError {}
    }

    @Test func everyNestedSourceReadRequiresBoundedCapability() async throws {
        let fixture = try await fixture()
        let store = BoundedOnlyStore(underlying: fixture.store)
        let result = try await NativePhysicalDesignRoutingSourceAdopter().adopt(fixture.input, store: store)
        #expect(result.lineage.parent == fixture.input.parent)
        let caps = await store.readCaps
        #expect(caps.count == 7 && caps.allSatisfy { $0 > 0 })
    }

    @Test func enlargedActualSourceFailsBoundedFilesystemIntake() async throws {
        let fixture = try await fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routing-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Temporary source cleanup failed: \(error)") } }
        var bindings: Set<PhysicalDesignArtifactBinding> = [fixture.input.parent.layoutArtifact]
        for request in [fixture.input.oldRequest, fixture.input.newRequest] {
            bindings.insert(try request.requireBinding(for: request.pdk.manifest))
            bindings.formUnion(request.processAssets.values)
        }
        for binding in bindings {
            let url = root.appendingPathComponent(binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try await fixture.store.read(binding)
            try bytes.write(to: url)
        }
        let source = try #require(fixture.input.newRequest.processAssets["tech"])
        let count = try #require(Int(exactly: source.reference.byteCount))
        try Data(repeating: 0, count: count + 1).write(to: root.appendingPathComponent(source.path))
        do {
            _ = try await NativePhysicalDesignRoutingSourceAdopter().adopt(fixture.input,
                store: FileSystemPhysicalDesignArtifactStore(projectRoot: root))
            Issue.record("An enlarged actual source received a revision.")
        } catch let error as PhysicalDesignRoutingSourceAdoptionError {
            #expect(error.reason == .sourceValidation)
            #expect(error.underlyingCause is PhysicalDesignStoreError)
        }
        #expect(try Data(contentsOf: root.appendingPathComponent(fixture.input.parent.layoutArtifact.path)) == fixture.parentBytes)
    }

    private actor BoundedOnlyStore: PhysicalDesignArtifactStore {
        let underlying: InMemoryPhysicalDesignArtifactStore
        private(set) var readCaps: [UInt64] = []
        init(underlying: InMemoryPhysicalDesignArtifactStore) { self.underlying = underlying }
        func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
            throw PhysicalDesignStoreError.readFailed("Unbounded intake is forbidden in this regression.")
        }
        func read(_ binding: PhysicalDesignArtifactBinding, maximumBytes: UInt64) async throws -> Data {
            guard maximumBytes == binding.reference.byteCount else {
                throw PhysicalDesignStoreError.readFailed("Nested read lost its exact source cap.")
            }
            readCaps.append(maximumBytes)
            return try await underlying.read(binding, maximumBytes: maximumBytes)
        }
        func write(_ artifacts: [PhysicalDesignArtifactWrite]) async throws -> [PhysicalDesignArtifactBinding] {
            throw PhysicalDesignStoreError.writeFailed("The intake regression does not publish artifacts.")
        }
    }

    @Test func typedResistanceCapacitanceAndGridFactsCannotChange() throws {
        let layer = LEFLayerDef(name: "M", type: .routing, direction: .horizontal,
            width: 0.1, spacing: 0.1, resistance: 1.25, capacitance: 0.2, edgeCapacitance: 0.3, thickness: 0.4)
        let old = LEFDocument(layers: [layer])
        for index in 0..<5 {
            var new = old
            switch index {
            case 0: new.layers[0].resistance = 1.5
            case 1: new.layers[0].capacitance = 0.25
            case 2: new.layers[0].edgeCapacitance = nil
            case 3: new.layers[0].thickness = 0.5
            default: new.manufacturingGrid = 0.01; new.dbuPerMicron = 2000
            }
            #expect(try !PhysicalDesignRoutingSourceFacts.preserved(old, in: new))
        }
        var extended = old; extended.layers.append(.init(name: "EXTRA", type: .cut))
        #expect(try PhysicalDesignRoutingSourceFacts.preserved(old, in: extended))
    }

    private func fixture(_ scenario: String = "valid") async throws -> (
        input: PhysicalDesignRoutingSourceAdoptionInput, store: InMemoryPhysicalDesignArtifactStore,
        parent: PhysicalDesignSnapshot, parentBytes: Data
    ) {
        let (base, store) = try await ProcessGeometryTests().fixtureSources()
        var configuration = ProcessGeometryTests().nativeRequest(base).configuration
        configuration.maximumRoutingLayer = 3
        configuration.implementationConstraints?.sourceRoutingWidthPolicy = .sourceDefault
        func request(pdk: PDKReference, bindings: [PhysicalDesignArtifactBinding],
                     assets: [String: PhysicalDesignArtifactBinding], parent: PhysicalDesignReference?,
                     configuration: PhysicalDesignConfiguration) -> PhysicalDesignRequest {
            .init(runID: "source-adoption", inputBindings: bindings, design: base.design, constraints: base.constraints,
                requestedModeIDs: base.requestedModeIDs, pdk: pdk, inputLayout: parent,
                stage: .detailedRouting, configuration: configuration, processAssets: assets)
        }
        let preparation = request(pdk: base.pdk, bindings: base.inputBindings, assets: base.processAssets,
            parent: nil, configuration: configuration)
        let oldInputs = try #require(try await PhysicalDesignProcessInputs.load(request: preparation, store: store))
        let oldGeometry = try PhysicalDesignProcessGeometry(inputs: oldInputs, request: preparation, units: 1000)
        func pin(_ id: String, x: Int64) -> PhysicalDesignSnapshot.Pin {
            .init(id: id, cellID: nil, name: id, x: x, y: 100, netID: "CLK", direction: id == "A" ? "input" : "output", accessLayer: 2,
                topPort: .init(rectangle: .init(x: -50, y: -50, width: 100, height: 100), layer: 2,
                    placementX: x, placementY: 100, orientation: .n, placementStatus: .fixed, use: .clock))
        }
        let raw = PhysicalDesignSnapshot(topCell: base.design.topDesignName, unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 2000, height: 2000), core: .init(x: 0, y: 0, width: 2000, height: 2000),
            pins: [pin("A", x: 100), pin("B", x: 900)], nets: [.init(id: "CLK", pinIDs: ["A", "B"], isClock: true)],
            clockTrees: [.init(id: "clock", netID: "CLK", sourcePinID: "A", sinkPinIDs: ["B"])],
            routes: [.init(id: "retained", netID: "CLK", segments: [.init(id: "wire", layer: 2,
                x1: 100, y1: 100, x2: 900, y2: 100, widthDBU: 100,
                endpointExtensions: .init(beginDBU: 50, endDBU: 50))], defStatus: .routed)],
            implementationState: .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 10),
                .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 5)]))
        let parent = try PhysicalDesignTechnologyConstraints.prepare(oldGeometry.bind(raw), request: preparation,
            processInputs: oldInputs, processGeometry: oldGeometry)
        try oldGeometry.validate(parent)
        let codec = PhysicalDesignJSONCodec()
        let parentBytes = try codec.encode(parent)
        let binding = try await store.registerInput(parentBytes, relativePath: "inputs/parent.json", kind: .layout, format: .json)
        let reference = PhysicalDesignReference(layoutArtifact: binding, topCell: parent.topCell,
            layoutDigest: binding.reference.digest.hexadecimalValue)
        let oldRequest = request(pdk: base.pdk, bindings: base.inputBindings, assets: base.processAssets,
            parent: reference, configuration: configuration)
        let oldTech = try #require(base.processAssets["tech"])
        var source = try #require(String(data: await store.read(oldTech), encoding: .utf8))
        if scenario == "width" { source = source.replacingOccurrences(of: "PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ;", with: "PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.2 ;") }
        var addition = """
        LAYER viaVX TYPE CUT ; WIDTH 0.05 ; SPACING 0.05 ; END viaVX
        LAYER metX TYPE ROUTING ; DIRECTION HORIZONTAL ; PITCH 0.6 ; OFFSET 0.3 ; WIDTH 0.1 ; SPACING 0.1 ; END metX
        VIA vx DEFAULT
          LAYER metV ; RECT -0.1 -0.1 0.1 0.1 ;
          LAYER viaVX ; RECT -0.025 -0.025 0.025 0.025 ;
          LAYER metX ; RECT -0.1 -0.1 0.1 0.1 ;
        END vx
        """
        if scenario == "grid" { addition = addition.replacingOccurrences(of: "OFFSET 0.3 ;", with: "") }
        if scenario == "generated" {
            addition += "\n" + """

            VIA generated GENERATE
              LAYER metV ; RECT -0.1 -0.1 0.1 0.1 ;
              LAYER viaVX ; RECT -0.025 -0.025 0.025 0.025 ;
              LAYER metX ; RECT -0.1 -0.1 0.1 0.1 ;
            END generated
            """
        }
        source = source.replacingOccurrences(of: "END LIBRARY", with: addition + "\nEND LIBRARY")
        let tech = try await store.registerInput(Data(source.utf8), relativePath: "inputs/extended.lef", kind: .technology, format: .lef)
        var manifest = try PDKManifestCodec.decode(data: await store.read(base.requireBinding(for: base.pdk.manifest)))
        let asset = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[asset].path = "extended.lef"; manifest.assets[asset].sha256 = tech.reference.digest.hexadecimalValue
        manifest.assets[asset].byteCount = Int64(tech.reference.byteCount)
        manifest.layers.append(.init(layerID: "VX", name: "viaVX", number: 5, purpose: .via, isRoutingLayer: false))
        manifest.layers.append(.init(layerID: "X", name: "metX", number: scenario == "collision" ? 3 : 6, purpose: .metal, isRoutingLayer: true))
        let mapping = try #require(manifest.crossViewMappings.firstIndex { $0.assetID == "tech" && $0.view == .lef })
        manifest.crossViewMappings[mapping].layerIDs += ["VX", "X"]
        var assets = base.processAssets; assets["tech"] = tech
        if scenario == "cell" {
            let oldCell = try #require(assets["cells"])
            var bytes = try await store.read(oldCell); bytes.append(Data("\n# A different source artifact.\n".utf8))
            let cell = try await store.registerInput(bytes, relativePath: "inputs/new-cells.lef", kind: .technology, format: .lef)
            assets["cells"] = cell
            let cellAsset = try #require(manifest.assets.firstIndex { $0.assetID == "cells" })
            manifest.assets[cellAsset].path = "new-cells.lef"; manifest.assets[cellAsset].sha256 = cell.reference.digest.hexadecimalValue
            manifest.assets[cellAsset].byteCount = Int64(cell.reference.byteCount)
        }
        let pdkBinding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/extended.json", kind: .technology, format: .json)
        let pdk = try PDKReference(manifest: pdkBinding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdkBinding),
            processID: base.pdk.processID, version: base.pdk.version)
        configuration.preferredRoutingLayers = [2, 3, 6]; configuration.maximumRoutingLayer = 6
        let retained = base.inputBindings.filter { $0.reference != base.pdk.manifest && $0.descriptor.format != .lef }
        let newRequest = request(pdk: pdk, bindings: retained + [pdkBinding], assets: assets,
            parent: reference, configuration: configuration)
        return (.init(parent: reference, oldRequest: oldRequest, newRequest: newRequest,
            limits: .init(maximumCombinedInputBytes: 1_048_576, maximumSourceAssets: 2, maximumSourceEntries: 10_000)), store, parent, parentBytes)
    }
}
