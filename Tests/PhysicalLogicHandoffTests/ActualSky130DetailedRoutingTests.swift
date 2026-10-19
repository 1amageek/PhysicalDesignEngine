import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import Darwin
import DEF
import Foundation
import LogicEngineCore
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PhysicalDesignLogicHandoff
import PDKCore
import Testing
@testable import PhysicalDesignCore

@Suite("Actual saved Sky130 CTS candidate detailed routing", .serialized, .timeLimit(.minutes(4)))
struct ActualSky130DetailedRoutingTests {
    private struct Running: LogicRunControlling { func checkpoint() throws(LogicKernelError) {} }
    private let codec = PhysicalDesignJSONCodec()
    private func context() throws -> LogicKernelContext {
        .init(limits: try .init(maximums: Dictionary(uniqueKeysWithValues:
            LogicResource.allCases.map { ($0, UInt64(1_000_000_000)) })), control: Running())
    }
    private func limits() throws -> PhysicalLogicHandoffLimits {
        try .init(maximumInstances: 100, maximumPins: 1000, maximumNets: 1000)
    }
    private func inputRoot(derived: Bool) throws -> URL {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHYSICAL_ROUTED_CTS_INPUT_ROOT"],
            "Provide the retained successful primary/derived Native CTS CLI cohort; this test does not rerun CTS"))
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let selected = entries.filter { $0.lastPathComponent.hasPrefix(derived ? "native-cts-derived-" : "native-cts-primary-") }
        try #require(selected.count == 1)
        return selected[0]
    }
    private func outputRoot(derived: Bool) throws -> URL {
        let parent = ProcessInfo.processInfo.environment["PHYSICAL_ROUTED_EVIDENCE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = parent.appending(path: "sky130-detailed-\(derived ? "derived" : "primary")-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func parentLogicReceipt(root: URL) throws -> LogicArtifactBinding {
        let path = root.appending(path: ".logic-engine/runs/checked-source/synthesis-receipt-v4.json")
        let data = try Data(contentsOf: path)
        let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: data, using: .sha256),
            byteCount: UInt64(data.count), descriptor: .init(role: .output, kind: .report, format: .json))
        return try LogicArtifactBinding.local(reference: reference, fileURL: path)
    }
    private func loadBaseline(root: URL) async throws -> (checked: LogicVerifiedSynthesis, binding: LogicArtifactBinding) {
        let path = root.appending(path: "full-source-baseline-binding.json")
        let binding = try codec.decode(LogicArtifactBinding.self, from: Data(contentsOf: path))
        let checked = try await NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
            .load(binding, limits: PhysicalLogicHandoffTests().limits())
        return (checked, binding)
    }
    private func correspondence(_ baseline: LogicVerifiedSynthesis, candidate: PhysicalDesignSnapshot) throws -> PhysicalLogicECOCorrespondence {
        var instances: [DesignEntityID: String] = [:], nets: [DesignEntityID: String] = [:]
        var ports: [DesignEntityID: [String]] = [:], states: [DesignEntityID: String] = [:]
        baseline.mapped.withTables { logicalNets, actual, _, logicalPorts, _, _ in
            for index in actual.indices {
                let name = "cell-\(index)"
                instances[actual[index].id] = name
                if let state = actual[index].stateID { states[state] = name }
            }
            for index in logicalNets.indices { nets[logicalNets[index].id] = "net-\(index)" }
            for index in logicalPorts.indices {
                ports[logicalPorts[index].id] = (0..<logicalPorts[index].bits.count).map { "port-\(index)-\($0)" }
            }
        }
        // These are the retained fixture's declared canonical identities, not inferred cell/pin aliases.
        for (index, cell) in candidate.cells.enumerated() where !instances.values.contains(cell.id) {
            instances[try .init(rawValue: UInt64.max - UInt64(index))] = cell.id
        }
        for (index, net) in candidate.nets.enumerated() where !nets.values.contains(net.id) {
            nets[try .init(rawValue: UInt64.max - 10_000 - UInt64(index))] = net.id
        }
        return .init(instanceIDs: instances, netIDs: nets, portPinIDs: ports, stateInstanceIDs: states)
    }
    private func cli(_ request: PhysicalDesignRequest, root: URL) async throws -> PhysicalDesignResult {
        let binary = try #require(ProcessInfo.processInfo.environment["PHYSICAL_DESIGN_CLI"])
        let requestURL = root.appending(path: "detailed-request.json"), resultURL = root.appending(path: "detailed-result.json")
        try codec.encode(request).write(to: requestURL)
        try Data().write(to: resultURL)
        let handle = try FileHandle(forWritingTo: resultURL)
        defer { do { try handle.close() } catch { Issue.record(error) } }
        let process = Process(); process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--request", requestURL.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!process.isRunning, "Detailed-routing CLI exceeded its explicit deadline")
        let result = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: resultURL))
        try #require(process.terminationStatus == 0, "\(result.diagnostics)")
        return result
    }

    private func input(_ bytes: Data, path: String, format: ArtifactFormat,
                       root: URL, store: any PhysicalDesignArtifactStore) async throws -> PhysicalDesignArtifactBinding {
        let binding = try await InMemoryPhysicalDesignArtifactStore().registerInput(bytes,
            relativePath: path, kind: .technology, format: format)
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .withoutOverwriting)
        let retained = try await store.read(binding)
        try #require(retained == bytes)
        return binding
    }
    private func routingRequest(_ original: PhysicalDesignRequest, parent: PhysicalDesignReference,
                                runID: String) -> PhysicalDesignRequest {
        PhysicalDesignRequest(runID: runID, inputBindings: original.inputBindings,
            design: original.design, constraints: original.constraints, requestedModeIDs: original.requestedModeIDs,
            pdk: original.pdk, inputLayout: parent, stage: .detailedRouting,
            configuration: original.configuration, executionIntent: .geometrySmoke,
            processAssets: original.processAssets)
    }
    private func adoptFullSource(_ original: PhysicalDesignRequest, parent: PhysicalDesignReference,
                                 before: PhysicalDesignSnapshot, root: URL,
                                 store: any PhysicalDesignArtifactStore) async throws -> (
                                    request: PhysicalDesignRequest, snapshot: PhysicalDesignSnapshot,
                                    lineage: PhysicalDesignArtifactBinding, manifest: PhysicalDesignArtifactBinding,
                                    oldContext: PhysicalDesignArtifactBinding, newContext: PhysicalDesignArtifactBinding) {
        let raw = try #require(original.inputBindings.first { $0.path.hasSuffix("original-technology.raw") })
        let bytes = try await store.read(raw)
        try #require(bytes.count == 18_167)
        try #require(try SHA256ContentDigester().digest(data: bytes, using: .sha256).hexadecimalValue
            == "5de46c6f7c2cf82599b93d30a6459465f770f63c85b36182c672782219938519")
        let technology = try await input(bytes, path: "inputs/full-nominal-technology.lef", format: .lef, root: root, store: store)
        let oldManifest = try PhysicalDesignArtifactBinding.require(original.pdk.manifest, in: original.inputBindings)
        var manifest = try PDKManifestCodec.decode(data: await store.read(oldManifest))
        let originalLayers = manifest.layers
        manifest.layers += [("met2", 6), ("via", 7), ("met3", 8), ("via2", 9),
            ("met4", 10), ("via3", 11), ("met5", 12), ("via4", 13), ("licon", 14)].map { name, number in
            let routing = name.hasPrefix("met")
            return PDKLayerDefinition(layerID: name, name: name, number: number,
                purpose: routing ? .metal : .via, isRoutingLayer: routing)
        }
        let techIndex = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[techIndex].path = technology.path
        manifest.assets[techIndex].kind = technology.descriptor.kind
        manifest.assets[techIndex].format = technology.descriptor.format
        manifest.assets[techIndex].sha256 = technology.reference.digest.hexadecimalValue
        manifest.assets[techIndex].byteCount = Int64(technology.reference.byteCount)
        let mapIndex = try #require(manifest.crossViewMappings.firstIndex { $0.assetID == "tech" && $0.view == .lef })
        manifest.crossViewMappings[mapIndex].layerIDs = manifest.layers.map(\.layerID)
        try #require(manifest.layers.prefix(originalLayers.count).elementsEqual(originalLayers))
        try #require(manifest.validate().isValid, "\(manifest.validate().findings)")
        let newManifest = try await input(PDKManifestCodec.encode(manifest), path: "inputs/full-source-process.json",
            format: .json, root: root, store: store)
        let oldRequest = routingRequest(original, parent: parent, runID: "actual-routing-source-adoption")
        var newRequest = oldRequest
        newRequest.pdk = try .init(manifest: newManifest.reference,
            manifestLocator: .init(location: ArtifactLocation(workspaceRelativePath: newManifest.path),
                role: .input, kind: .technology, format: .json), processID: original.pdk.processID, version: original.pdk.version)
        newRequest.processAssets["tech"] = technology
        newRequest.configuration.preferredRoutingLayers = [1, 2, 6, 8, 10, 12]
        newRequest.configuration.maximumRoutingLayer = 12
        let oldTechnology = try #require(oldRequest.processAssets["tech"])
        let historicalReferences = Set([oldTechnology.reference, oldManifest.reference, raw.reference])
        newRequest.inputBindings = oldRequest.inputBindings.filter { !historicalReferences.contains($0.reference) } + [technology, newManifest]
        newRequest = routingRequest(newRequest, parent: parent, runID: "actual-routing-source-adoption")
        try #require(!newRequest.inputs.contains(raw.reference) && !newRequest.inputs.contains(oldTechnology.reference))
        try #require(Set(newRequest.inputs.map(\.id)).count == newRequest.inputs.count)
        let sourceBindings = Array(oldRequest.processAssets.values) + Array(newRequest.processAssets.values)
        var combined = parent.layoutArtifact.reference.byteCount
        for reference in [oldRequest.pdk.manifest, newRequest.pdk.manifest] + sourceBindings.map(\.reference) {
            let addition = combined.addingReportingOverflow(reference.byteCount)
            try #require(!addition.overflow); combined = addition.partialValue
        }
        let byteLimit = try #require(Int(exactly: combined))
        let limits = PhysicalDesignRoutingSourceAdoptionInput.Limits(maximumCombinedInputBytes: byteLimit,
            maximumSourceAssets: sourceBindings.count, maximumSourceEntries: byteLimit)
        let oldContext = try await store.write(codec.encode(oldRequest), logicalID: "routing-source-adoption-old-request",
            relativePath: "inputs/source-adoption-old-request.json", kind: .report, format: .json, runID: "actual-routing-source-adoption")
        let newContext = try await store.write(codec.encode(newRequest), logicalID: "routing-source-adoption-new-request",
            relativePath: "inputs/source-adoption-new-request.json", kind: .report, format: .json, runID: "actual-routing-source-adoption")
        let adopter: any PhysicalDesignRoutingSourceAdopting = NativePhysicalDesignRoutingSourceAdopter()
        let adopted = try await adopter.adopt(.init(parent: parent, oldRequest: oldRequest,
            newRequest: newRequest, limits: limits), store: store)
        try #require(adopted.snapshot.cells == before.cells && adopted.snapshot.nets == before.nets
            && adopted.snapshot.pins == before.pins && adopted.snapshot.rows == before.rows)
        try #require(adopted.snapshot.routes == before.routes && adopted.snapshot.vias == before.vias)
        var expectedTrees = before.clockTrees
        for index in expectedTrees.indices { expectedTrees[index].timingEstimate = nil }
        try #require(adopted.snapshot.clockTrees == expectedTrees)
        let oldTracks = try #require(before.implementationState).tracks
        let tracks = try #require(adopted.snapshot.implementationState).tracks
        for track in oldTracks { try #require(tracks.contains(track)) }
        try #require(Set(tracks.map(\.layer)) == Set([1, 2, 6, 8, 10, 12]))
        try #require(adopted.lineage.parent == parent && adopted.lineage.oldManifest == original.pdk.manifest
            && adopted.lineage.newManifest == newManifest.reference)
        try #require(adopted.lineage.oldAssets["cells"] == adopted.lineage.newAssets["cells"])
        try #require(adopted.lineage.newAssets["tech"] == technology.reference && !adopted.lineage.checkedFactIDs.isEmpty)
        let lineage = try await store.write(codec.encode(adopted.lineage), logicalID: "routing-source-adoption-lineage",
            relativePath: "inputs/routing-source-adoption-lineage.json", kind: .report, format: .json,
            runID: "actual-routing-source-adoption")
        let saved = try await store.write(codec.encode(adopted.snapshot), logicalID: "routing-source-adopted-input",
            relativePath: "inputs/routing-source-adopted-input.json", kind: .layout, format: .json,
            runID: "actual-routing-source-adoption")
        let savedLineage = try codec.decode(PhysicalDesignRoutingSourceAdoptionLineage.self, from: await store.read(lineage))
        let savedSnapshot = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(saved))
        try #require(savedLineage == adopted.lineage && savedSnapshot == adopted.snapshot)
        let reference = PhysicalDesignReference(layoutArtifact: saved, topCell: adopted.snapshot.topCell,
            layoutDigest: saved.reference.digest.hexadecimalValue)
        newRequest = routingRequest(newRequest, parent: reference, runID: "actual-detailed")
        newRequest.inputBindings.append(lineage); newRequest.inputs.append(lineage.reference)
        return (newRequest, adopted.snapshot, lineage, newManifest, oldContext, newContext)
    }

    private struct Material {
        let layer: Int
        let rectangle: PhysicalDesignSnapshot.Rect
        let terminal: String?
        let contact: String?
    }
    private enum ConnectivityError: Error {
        case disconnected(net: String, terminals: Set<String>)
    }
    private func hasMetalContact(_ a: PhysicalDesignSnapshot.Rect, _ b: PhysicalDesignSnapshot.Rect) -> Bool {
        let xOverlap = max(a.x, b.x) < min(a.maxX, b.maxX)
        let yOverlap = max(a.y, b.y) < min(a.maxY, b.maxY)
        return (xOverlap && yOverlap)
            || (xOverlap && (a.maxY == b.y || b.maxY == a.y))
            || (yOverlap && (a.maxX == b.x || b.maxX == a.x))
    }
    @Test("Exact metal adjacency retains fractured edges and refuses corner, gap and layer shortcuts")
    func exactMetalContactBoundaries() {
        let first = Material(layer: 1, rectangle: .init(x: 6885, y: 4295, width: 330, height: 845), terminal: "Q", contact: nil)
        let edge = Material(layer: 1, rectangle: .init(x: 6885, y: 4215, width: 390, height: 80), terminal: "Q", contact: nil)
        let overlap = Material(layer: 1, rectangle: .init(x: 6885, y: 4215, width: 390, height: 81), terminal: "Q", contact: nil)
        let gap = Material(layer: 1, rectangle: .init(x: 6885, y: 4215, width: 390, height: 79), terminal: "Q", contact: nil)
        let corner = Material(layer: 1, rectangle: .init(x: 7215, y: 4215, width: 390, height: 80), terminal: "Q", contact: nil)
        let otherLayer = Material(layer: 2, rectangle: edge.rectangle, terminal: "Q", contact: nil)
        #expect(materialsConnect(first, edge))
        #expect(materialsConnect(edge, first))
        #expect(materialsConnect(first, overlap))
        #expect(!materialsConnect(first, gap))
        #expect(!materialsConnect(first, corner))
        #expect(!materialsConnect(first, otherLayer))
    }
    private func materialsConnect(_ a: Material, _ b: Material) -> Bool {
        let contact = a.contact != nil && a.contact == b.contact
        return contact || (a.layer == b.layer && hasMetalContact(a.rectangle, b.rectangle))
    }
    private func verifyConnectivity(_ snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws {
        var probes = 0
        for net in snapshot.nets {
            try #require(!net.pinIDs.isEmpty)
            var records: [Material] = []
            for route in snapshot.routes where route.netID == net.id {
                for segment in route.segments {
                    records.append(.init(layer: segment.layer, rectangle: try segment.qualifiedFootprint(), terminal: nil, contact: nil))
                }
            }
            for via in snapshot.vias where via.netID == net.id {
                for shape in try geometry.viaShapes(master: try #require(via.master), x: via.x, y: via.y) {
                    let xs = shape.points.map { Int64($0.x) }, ys = shape.points.map { Int64($0.y) }
                    let x = try #require(xs.min()), y = try #require(ys.min())
                    let maxX = try #require(xs.max()), maxY = try #require(ys.max())
                    try #require(Set(zip(xs, ys).map { "\($0.0),\($0.1)" }).count == 4
                        && xs.allSatisfy { $0 == x || $0 == maxX } && ys.allSatisfy { $0 == y || $0 == maxY },
                        "This independent connectivity reference requires actual rectangular source contacts")
                    records.append(.init(layer: Int(shape.layer), rectangle: .init(x: x, y: y, width: maxX - x, height: maxY - y), terminal: nil, contact: via.id))
                }
            }
            for id in net.pinIDs {
                let pin = try #require(snapshot.pins.first { $0.id == id })
                if let cellID = pin.cellID {
                    let cell = try #require(snapshot.cells.first { $0.id == cellID })
                    for shape in try geometry.pinShapes(master: cell.master, pin: pin.name, orientation: cell.orientation, x: cell.x, y: cell.y) {
                        let xs = shape.points.map { Int64($0.x) }, ys = shape.points.map { Int64($0.y) }
                        let x = try #require(xs.min()), y = try #require(ys.min())
                        let maxX = try #require(xs.max()), maxY = try #require(ys.max())
                        try #require(Set(zip(xs, ys).map { "\($0.0),\($0.1)" }).count == 4
                        && xs.allSatisfy { $0 == x || $0 == maxX } && ys.allSatisfy { $0 == y || $0 == maxY },
                            "This reference does not approximate polygon PORTs by their bounding boxes")
                        records.append(.init(layer: Int(shape.layer), rectangle: .init(x: x, y: y, width: maxX - x, height: maxY - y), terminal: id, contact: nil))
                    }
                } else {
                    let port = try #require(pin.topPort)
                    records.append(.init(layer: port.layer, rectangle: try port.worldRectangle(), terminal: id, contact: nil))
                }
            }
            try #require(records.count <= 100_000 && !records.isEmpty)
            let first = try #require(records.firstIndex { $0.terminal == net.pinIDs.first })
            var visited: Set<Int> = [first], queue = [first], cursor = 0
            while cursor < queue.count {
                let a = records[queue[cursor]]; cursor += 1
                for index in records.indices where !visited.contains(index) {
                    probes += 1; try #require(probes <= 1_000_000)
                    let b = records[index]
                    if materialsConnect(a, b) {
                        visited.insert(index); queue.append(index)
                    }
                }
            }
            guard visited.count == records.count else {
                let terminals = Set(records.indices.filter { !visited.contains($0) }.compactMap { records[$0].terminal })
                throw ConnectivityError.disconnected(net: net.id, terminals: terminals)
            }
        }
    }
    private func verifyDEF(_ bytes: Data, snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws {
        let document = try DEFLibraryReader.read(bytes)
        try #require(document.designName == snapshot.topCell && document.dbuPerMicron == Double(snapshot.unitsPerMicron))
        try #require(Set(document.nets.map(\.name)) == Set(snapshot.nets.map(\.id)))
        for net in document.nets {
            var remaining = snapshot.routes.filter { $0.netID == net.name }.flatMap(\.segments)
            var contacts = snapshot.vias.filter { $0.netID == net.name }
            for route in net.routing {
                let layer = try #require(geometry.layers.first { $0.value.name == route.layerName }?.key)
                if let master = route.viaName {
                    try #require(route.points.count == 1)
                    let point = route.points[0]
                    let index = try #require(contacts.firstIndex { $0.master == master && $0.x == Int64(point.x) && $0.y == Int64(point.y) && $0.lowerLayer == Int(layer) })
                    contacts.remove(at: index)
                } else {
                    try #require(route.points.count == 2 && route.pointExtensions.count == 2)
                    let width = try geometry.routingWidthAndSpacing(layer: Int(layer), units: snapshot.unitsPerMicron, width: nil, areaHandledSeparately: true).width
                    let a = route.points[0], b = route.points[1]
                    let decoded = PhysicalDesignSnapshot.RouteSegment(id: "readback", layer: Int(layer), x1: Int64(a.x), y1: Int64(a.y), x2: Int64(b.x), y2: Int64(b.y), widthDBU: width,
                        endpointExtensions: .init(beginDBU: Int64(try #require(route.pointExtensions[0])), endDBU: Int64(try #require(route.pointExtensions[1]))))
                    let footprint = try decoded.qualifiedFootprint()
                    let index = try #require(try remaining.firstIndex { segment in
                        guard segment.layer == Int(layer) else { return false }
                        return try segment.qualifiedFootprint() == footprint
                    })
                    remaining.remove(at: index)
                }
            }
            try #require(remaining.isEmpty && contacts.isEmpty)
        }
    }
    private struct Handoff: Codable {
        let checkedCandidate: PhysicalLogicCheckedCandidateArtifacts
        let routedDEF: PhysicalDesignArtifactBinding
        let routedTechnologyLEF: ArtifactReference
        let cornerTechnologyLEF: ArtifactReference
        let standardCellLEF: ArtifactReference
        let sourceSelectionReport: ArtifactReference
        let sourceAdoptedInput: PhysicalDesignReference
        let sourceAdoptionLineage: PhysicalDesignArtifactBinding
        let routingManifest: PhysicalDesignArtifactBinding
        let functionalBaseline: LogicArtifactBinding
        let scope: String
    }

    private struct SourceInputs: Codable {
        let schemaVersion: Int
        let sourceParent: PhysicalDesignReference
        let oldRequest: PhysicalDesignArtifactBinding
        let newRequest: PhysicalDesignArtifactBinding
        let routingRequest: PhysicalDesignArtifactBinding
        let sourceAdoptedInput: PhysicalDesignReference
        let sourceAdoptionLineage: PhysicalDesignArtifactBinding
        let routingManifest: PhysicalDesignArtifactBinding
        let routingTechnology: PhysicalDesignArtifactBinding
        let standardCellLEF: PhysicalDesignArtifactBinding
        let liberty: PhysicalDesignArtifactBinding
        let parentLogicReceipt: LogicArtifactBinding
        let historicalRawTechnology: ArtifactReference
    }

    @Test("Prepare four explicit full-source inputs for fresh checked Logic baselines", arguments: [false, true])
    func prepareFullSourceInputs(derived: Bool) async throws {
        try #require(ProcessInfo.processInfo.environment["PHYSICAL_ROUTED_EVIDENCE_ROOT"] != nil,
            "Input preparation requires a retained output root for the separate checked-baseline stage")
        let input = try inputRoot(derived: derived), output = try outputRoot(derived: derived)
        let initialRequest = try codec.decode(PhysicalDesignRequest.self, from: Data(contentsOf: input.appending(path: "actual-cts-request.json")))
        let initialResult = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: input.appending(path: "actual-cts-result.json")))
        try #require(initialResult.status == .completed)
        let parent = try #require(initialResult.payload.physicalDesign)
        let initialStore = FileSystemPhysicalDesignArtifactStore(projectRoot: input)
        let before = try codec.decode(PhysicalDesignSnapshot.self, from: await initialStore.read(parent.layoutArtifact))
        var adoptedInput: PhysicalDesignReference?
        var adoptedBytes: Data?
        for path in ["api", "cli"] {
            let root = output.appending(path: path)
            try FileManager.default.copyItem(at: input, to: root)
            let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
            let adopted = try await adoptFullSource(initialRequest, parent: parent, before: before, root: root, store: store)
            var request = adopted.request; request.runID = "actual-detailed-\(path)"
            let inputReference = try #require(request.inputLayout)
            let inputBytes = try await store.read(inputReference.layoutArtifact)
            if let adoptedInput, let adoptedBytes {
                try #require(inputReference == adoptedInput && inputBytes == adoptedBytes)
            } else { adoptedInput = inputReference; adoptedBytes = inputBytes }
            let requestBinding = try await store.write(codec.encode(request), logicalID: "full-source-routing-request",
                relativePath: "inputs/full-source-routing-request.json", kind: .report, format: .json, runID: request.runID)
            let source = SourceInputs(schemaVersion: 1, sourceParent: parent, oldRequest: adopted.oldContext,
                newRequest: adopted.newContext, routingRequest: requestBinding, sourceAdoptedInput: inputReference,
                sourceAdoptionLineage: adopted.lineage, routingManifest: adopted.manifest,
                routingTechnology: try #require(request.processAssets["tech"]),
                standardCellLEF: try #require(request.processAssets["cells"]),
                liberty: try #require(initialRequest.inputBindings.first { $0.descriptor.format == .liberty }),
                parentLogicReceipt: try parentLogicReceipt(root: root),
                historicalRawTechnology: try #require(initialRequest.inputBindings.first { $0.path.hasSuffix("original-technology.raw") }).reference)
            _ = try await store.write(codec.encode(source), logicalID: "routing-source-inputs",
                relativePath: "routing-source-inputs.json", kind: .report, format: .json, runID: request.runID)
            print("ACTUAL_SKY130_FULL_SOURCE_INPUT_PREPARED path=\(path) derived=\(derived) root=\(root.path)")
        }
    }

    private func preparedRoot(derived: Bool) throws -> URL {
        let parent = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHYSICAL_ROUTED_PREPARED_INPUT_ROOT"],
            "Routing consumes the explicitly prepared four-subject cohort and its fresh checked baselines"))
        let entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        let selected = entries.filter { $0.lastPathComponent.hasPrefix("sky130-detailed-\(derived ? "derived" : "primary")-") }
        try #require(selected.count == 1)
        return selected[0]
    }

    @Test("Primary API executes routing and complete saved-source proof validation")
    func actualDetailedRoutingPrimaryAPI() async throws {
        try await actualDetailedRouting(derived: false, path: "api", savedResult: false)
    }

    @Test("Primary CLI executes routing and complete saved-source proof validation")
    func actualDetailedRoutingPrimaryCLI() async throws {
        try await actualDetailedRouting(derived: false, path: "cli", savedResult: false)
    }

    @Test("Derived API executes routing and complete saved-source proof validation")
    func actualDetailedRoutingDerivedAPI() async throws {
        try await actualDetailedRouting(derived: true, path: "api", savedResult: false)
    }

    @Test("Derived CLI executes routing and complete saved-source proof validation")
    func actualDetailedRoutingDerivedCLI() async throws {
        try await actualDetailedRouting(derived: true, path: "cli", savedResult: false)
    }

    @Test("Primary API saved completed result repeats complete validation without routing")
    func validateSavedDetailedRoutingPrimaryAPI() async throws {
        try await actualDetailedRouting(derived: false, path: "api", savedResult: true)
    }

    @Test("Primary CLI saved completed result repeats complete validation without routing")
    func validateSavedDetailedRoutingPrimaryCLI() async throws {
        try await actualDetailedRouting(derived: false, path: "cli", savedResult: true)
    }

    @Test("Derived API saved completed result repeats complete validation without routing")
    func validateSavedDetailedRoutingDerivedAPI() async throws {
        try await actualDetailedRouting(derived: true, path: "api", savedResult: true)
    }

    @Test("Derived CLI saved completed result repeats complete validation without routing")
    func validateSavedDetailedRoutingDerivedCLI() async throws {
        try await actualDetailedRouting(derived: true, path: "cli", savedResult: true)
    }

    private func actualDetailedRouting(derived: Bool, path: String, savedResult: Bool) async throws {
        let output = try preparedRoot(derived: derived)
        let root = output.appending(path: path)
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let source = try codec.decode(SourceInputs.self, from: Data(contentsOf: root.appending(path: "routing-source-inputs.json")))
        try #require(source.schemaVersion == 1)
        let request = try codec.decode(PhysicalDesignRequest.self, from: await store.read(source.routingRequest))
        let inputReference = try #require(request.inputLayout)
        try #require(inputReference == source.sourceAdoptedInput && request.pdk.manifest == source.routingManifest.reference)
        let inputBytes = try await store.read(inputReference.layoutArtifact)
        let adoptedSnapshot = try codec.decode(PhysicalDesignSnapshot.self, from: inputBytes)
        let peerRoot = output.appending(path: path == "api" ? "cli" : "api")
        let peerStore = FileSystemPhysicalDesignArtifactStore(projectRoot: peerRoot)
        let peerSource = try codec.decode(SourceInputs.self, from: Data(contentsOf: peerRoot.appending(path: "routing-source-inputs.json")))
        let peerBytes = try await peerStore.read(peerSource.sourceAdoptedInput.layoutArtifact)
        try #require(inputReference == peerSource.sourceAdoptedInput && inputBytes == peerBytes)
        let before = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(source.sourceParent.layoutArtifact))
        let clocks = Set(before.clockTrees.map(\.netID)).union(before.pins.compactMap { pin in
            before.clockTrees.contains { $0.bufferCellIDs.contains(pin.cellID ?? "") } ? pin.netID : nil
        }).union(before.clockTrees.flatMap(\.sinkPinIDs).compactMap { id in before.pins.first { $0.id == id }?.netID })
        let resultURL = root.appending(path: "detailed-result.json")
        let result: PhysicalDesignResult
        if savedResult {
            let bytes = try Data(contentsOf: resultURL)
            try #require(!bytes.isEmpty, "Saved routing validation requires a complete result, not an empty CLI capture")
            result = try codec.decode(PhysicalDesignResult.self, from: bytes)
        } else {
            try codec.encode(request).write(to: root.appending(path: "detailed-request.json"))
            if path == "api" {
                result = try await NativePhysicalDesignExecutor(expectedStage: .detailedRouting, artifactStore: store).execute(request)
            } else { result = try await cli(request, root: root) }
            try codec.encode(result).write(to: resultURL)
        }
        try #require(result.status == .completed, "\(result.diagnostics)")
        try #require(result.runID == request.runID)
        let reference = try #require(result.payload.physicalDesign)
        let snapshot = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: snapshot.unitsPerMicron)
        try geometry.validate(snapshot)
        try #require(geometry.vias.count == 25)
        try #require(snapshot.metadata["routingSourceAdoptionLineage"] == adoptedSnapshot.metadata["routingSourceAdoptionLineage"])
        try #require(snapshot.cells == before.cells && snapshot.nets == before.nets)
        try #require(snapshot.routes.filter { clocks.contains($0.netID) } == before.routes.filter { clocks.contains($0.netID) })
        try #require(snapshot.vias.filter { clocks.contains($0.netID) } == before.vias.filter { clocks.contains($0.netID) })
        try #require(snapshot.routes != before.routes && snapshot.clockTrees.allSatisfy { $0.timingEstimate == nil })
        try #require(snapshot.metadata["clockTimingStatus"] == "invalidated_by_routing_constraints_or_geometry")
        for net in snapshot.nets where !clocks.contains(net.id) { try #require(snapshot.routes.contains { $0.netID == net.id }) }
        try verifyConnectivity(snapshot, geometry: geometry)
        if path == "api" && !derived {
            var disconnected = snapshot
            let routeIndex = try #require(disconnected.routes.firstIndex { $0.netID == "net-0" })
            let bridges = disconnected.routes[routeIndex].segments.indices.filter {
                disconnected.routes[routeIndex].segments[$0].layer == 6
            }
            try #require(bridges.count == 1)
            disconnected.routes[routeIndex].segments.remove(at: bridges[0])
            do {
                try verifyConnectivity(disconnected, geometry: geometry)
                Issue.record("Removing the actual met2 bridge must disconnect the retained output terminal")
            } catch ConnectivityError.disconnected(let net, let terminals) {
                try #require(net == "net-0" && terminals.contains("port-2-0"))
            }
        }
        let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        try verifyDEF(await store.read(def), snapshot: snapshot, geometry: geometry)
        for binding in result.artifactBindings { _ = try await store.read(binding) }
        try #require(result.payload.claims.production == .blocked)
        let loaded = try await loadBaseline(root: root)
        let baseline = loaded.checked
        try #require(baseline.request.library.reference == source.liberty.reference)
        let scope = try #require(baseline.request.operatingProcessScope)
        try #require(scope.pdkManifest.reference == source.routingManifest.reference
            && scope.processID == request.pdk.processID && scope.pdkVersion == request.pdk.version)
        var run = try context()
        let assessment = try NativePhysicalLogicECOChecker().check(baseline, candidate: snapshot,
            correspondence: correspondence(baseline, candidate: snapshot), limits: limits(), context: &run)
        guard case .equivalent(let proof) = assessment.verdict else { Issue.record("Routed candidate is not equivalent"); return }
        try proof.requireBinding(to: assessment.problem)
        let persistence: any PhysicalLogicCheckedCandidatePersisting = NativePhysicalLogicCheckedCandidatePersistence()
        let artifacts = try await persistence.persist(assessment, candidateReference: reference, store: store,
            runID: request.runID, relativeDirectory: "runs/\(request.runID)/checked-candidate", limits: limits(),
            maximumArtifactBytes: 10_000_000, context: &run, isolation: #isolation)
        let reloaded = try await persistence.reload(artifacts, baseline: baseline, store: store, limits: limits(),
            maximumArtifactBytes: 10_000_000, context: &run, isolation: #isolation)
        try reloaded.requireBinding(to: snapshot)
        guard case .equivalent(let checked) = reloaded.verdict else { Issue.record("Saved proof did not reload checked"); return }
        try checked.requireBinding(to: reloaded.problem)
        let selection = try #require(request.inputBindings.first { $0.path.hasSuffix("selection-report.json") })
        let handoff = Handoff(checkedCandidate: artifacts, routedDEF: def,
            routedTechnologyLEF: try #require(request.processAssets["tech"]).reference,
            cornerTechnologyLEF: try #require(request.processAssets["tech"]).reference, standardCellLEF: try #require(request.processAssets["cells"]).reference,
            sourceSelectionReport: selection.reference, sourceAdoptedInput: inputReference,
            sourceAdoptionLineage: source.sourceAdoptionLineage, routingManifest: source.routingManifest,
            functionalBaseline: loaded.binding,
            scope: "Exact saved routed candidate and checked functional source; routed PEX/STA and process qualification still required")
        let handoffBytes = try codec.encode(handoff)
        let handoffURL = root.appending(path: "routed-pex-handoff.json")
        if FileManager.default.fileExists(atPath: handoffURL.path) {
            let retained = try Data(contentsOf: handoffURL)
            try #require(retained == handoffBytes, "Saved handoff must match the fully revalidated immutable candidate")
        } else { try handoffBytes.write(to: handoffURL, options: .withoutOverwriting) }
        print("ACTUAL_SKY130_DETAILED_ROUTE_SAVED_PROOF_OK path=\(path) derived=\(derived) routes=\(snapshot.routes.count) vias=\(snapshot.vias.count)")
    }
}
