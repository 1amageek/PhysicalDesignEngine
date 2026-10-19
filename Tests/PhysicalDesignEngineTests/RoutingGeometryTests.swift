import Foundation
import Testing
import DEF
import LayoutIR
import MaskGeometry
import PhysicalDesignEngine
@testable import PhysicalDesignCore

@Suite("Source-bound routing geometry")
struct RoutingGeometryTests {
    @Test("boundary-only source PORT points cannot qualify a width-aware native conductor", .timeLimit(.minutes(1)))
    func boundaryOnlyAccess() async throws {
        let (geometry, base, _) = try await ProcessGeometryTests().fixture()
        var request = ProcessGeometryTests().nativeRequest(base)
        request.stage = .globalRouting
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        snapshot.cells = [
            .init(id: "U1", master: "INV_X1", x: 500, y: 1000, width: 2000, height: 1000, placed: true),
            .init(id: "U2", master: "INV_X1", x: 1900, y: 2000, width: 2000, height: 1000, placed: true)
        ]
        snapshot.pins = [
            .init(id: "Y", cellID: "U1", name: "Y", x: 700, y: 1100, netID: "N", direction: "output", accessLayer: 2),
            .init(id: "A", cellID: "U2", name: "A", x: 2100, y: 2000, netID: "N", direction: "input", accessLayer: 2)
        ]
        snapshot.nets = [.init(id: "N", pinIDs: ["Y", "A"])]
        snapshot.rows = [1000, 2000].map { .init(id: "row_\($0)", originX: 0, originY: Int64($0), siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit") }
        snapshot.implementationState = .init(tracks: [
            .init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 50),
            .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 25)
        ])
        try geometry.validate(snapshot)
        let outcome = await PhysicalDesignNativeMutationEngine().applyPrepared(request, to: snapshot, processGeometry: geometry)
        #expect(outcome.status == .blocked && outcome.snapshot == nil)
        #expect(outcome.diagnostics.contains { $0.code.rawValue == "routing_pin_access_unavailable" })
    }
    @Test("actual API routes source PORT areas around blockages and OBS with lossless standard geometry", .timeLimit(.minutes(1)), arguments: ["valid", "ambiguous-default-via", "spacing-table", "spacing-table-polygon", "manufacturing-grid", "minimum-area", "minimum-area-repair", "minimum-area-table"])
    func nativeRouteAndResume(_ scenario: String) async throws {
        let fixture = try await prepared(scenario)
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(fixture.request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        #expect(result.provenance.producer.version == NativePhysicalDesignExecutor.currentImplementationVersion)
        let reference = try #require(result.payload.physicalDesign)
        let codec = PhysicalDesignJSONCodec()
        let output = try codec.decode(PhysicalDesignSnapshot.self, from: await fixture.store.read(reference.layoutArtifact))
        try verify(output, input: try #require(fixture.request.initialSnapshot), geometry: fixture.geometry)
        if scenario == "ambiguous-default-via" {
            #expect(!output.vias.isEmpty && output.vias.allSatisfy { $0.master == "hv" })
        }
        if scenario == "minimum-area-repair" || scenario == "minimum-area-table" {
            #expect(output.routes.flatMap(\.segments).contains { ($0.endpointExtensions?.beginDBU ?? 0) > 50 || ($0.endpointExtensions?.endDBU ?? 0) > 50 })
        }
        let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        try verifyDEF(await fixture.store.read(def), snapshot: output, geometry: fixture.geometry)
        for binding in result.artifactBindings { _ = try await fixture.store.read(binding) }
        #expect(result.payload.claims.geometry == .verified && result.payload.claims.timing == .notApplicable && result.payload.claims.production == .blocked)
        var resumed = PhysicalDesignRequest(runID: "routing-detail", inputBindings: fixture.request.inputBindings + [reference.layoutArtifact], design: fixture.request.design,
            constraints: fixture.request.constraints, requestedModeIDs: fixture.request.requestedModeIDs, pdk: fixture.request.pdk, inputLayout: reference,
            stage: .detailedRouting, configuration: fixture.request.configuration, processAssets: fixture.request.processAssets)
        let detailed = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(resumed)
        #expect(detailed.status == .completed, "\(detailed.diagnostics)")
        let detail = try codec.decode(PhysicalDesignSnapshot.self, from: await fixture.store.read(try #require(detailed.payload.physicalDesign?.layoutArtifact)))
        #expect(detail.routes == output.routes && detail.vias == output.vias && detail.pins == output.pins)
        resumed.stage = .timingECO; resumed.runID = "routing-eco"
        resumed.configuration.ecoAction = .rerouteNet; resumed.configuration.ecoTargetNetID = "N"
        let eco = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(resumed)
        #expect(eco.status == .completed, "\(eco.diagnostics)")
        #expect(eco.payload.claims.production == .blocked)
    }

    @Test("source router rejects missing semantics, unavailable paths and lower caller budgets atomically", .timeLimit(.minutes(1)), arguments: [
        "budget", "width", "retained-width", "retained-offcore", "no-path", "no-default-via", "offset-via", "cut-obs", "port-cut-spacing", "power-net", "spacing-table-source-violation", "manufacturing-grid-output", "minimum-area-impossible"
    ])
    func rejects(_ scenario: String) async throws {
        let fixture = try await prepared(scenario)
        var request = fixture.request
        switch scenario {
        case "power-net": request.initialSnapshot?.nets.append(.init(id: "VDD", pinIDs: []))
        case "budget": request.configuration.maximumRoutingCandidateChecks = 1
        case "width": request.configuration.implementationConstraints?.routeWidth = 102
        case "retained-width": request.initialSnapshot?.routes = [.init(id: "old", netID: "N", segments: [.init(id: "old-h", layer: 2, x1: 1900, y1: 1300, x2: 2100, y2: 1300)])]
        case "retained-offcore": request.initialSnapshot?.routes = [.init(id: "old", netID: "N", segments: [.init(id: "old-h", layer: 2, x1: 0, y1: 900, x2: 500, y2: 900, widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))])]
        case "no-path": request.initialSnapshot?.blockages = [.init(x: 2800, y: 0, width: 1000, height: 10000)]
        default: break
        }
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
        let code: String
        switch scenario {
        case "power-net": code = "routing_special_nets_unsupported"
        case "budget": code = "routing_candidate_budget_exhausted"
        case "width": code = "routing_width_unsupported"
        case "retained-width": code = "routing_retained_width_missing"
        case "retained-offcore": code = "routing_retained_geometry_invalid"
        case "port-cut-spacing": code = "routing_source_geometry_invalid"
        case "spacing-table-source-violation": code = "routing_final_spacing_invalid"
        case "manufacturing-grid-output": code = "routing_source_geometry_invalid"
        case "minimum-area-impossible": code = "routing_minimum_area_unrepairable"
        default: code = "routing_path_unavailable"
        }
        #expect(result.diagnostics.contains { $0.code.rawValue == code }, "\(result.diagnostics)")
        #expect(await fixture.store.data(at: "runs/\(request.runID)/physical-design/globalRouting/revision.json") == nil)
    }

    @Test("qualified retained metal may cross preferred tracks and survives API reload", .timeLimit(.minutes(1)))
    func retainedOffpreferredDirectionIsPhysicalGeometry() async throws {
        let fixture = try await prepared()
        var request = fixture.request
        request.runID = "retained-offpreferred"; request.stage = .timingECO
        request.configuration.ecoAction = .rerouteNet; request.configuration.ecoTargetNetID = "N"
        let retained = PhysicalDesignSnapshot.Route(id: "old", netID: "M", segments: [.init(id: "old-jog", layer: 2,
            x1: 8300, y1: 8900, x2: 8300, y2: 9100, widthDBU: 100,
            endpointExtensions: .init(beginDBU: 50, endDBU: 50))], defStatus: .routed)
        request.initialSnapshot?.nets.append(.init(id: "M", pinIDs: []))
        request.initialSnapshot?.routes = [retained]
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let reference = try #require(result.payload.physicalDesign)
        let codec = PhysicalDesignJSONCodec()
        let saved = try codec.decode(PhysicalDesignSnapshot.self, from: await fixture.store.read(reference.layoutArtifact))
        #expect(saved.routes.first { $0.netID == "M" } == retained)
        try fixture.geometry.validate(saved)
        let resumed = PhysicalDesignRequest(runID: "retained-offpreferred-reload",
            inputBindings: request.inputBindings + [reference.layoutArtifact], design: request.design,
            constraints: request.constraints, requestedModeIDs: request.requestedModeIDs, pdk: request.pdk,
            inputLayout: reference, stage: .timingECO, configuration: request.configuration, processAssets: request.processAssets)
        let rerun = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(resumed)
        #expect(rerun.status == .completed, "\(rerun.diagnostics)")
        let reread = try codec.decode(PhysicalDesignSnapshot.self,
            from: await fixture.store.read(try #require(rerun.payload.physicalDesign?.layoutArtifact)))
        #expect(reread.routes.first { $0.netID == "M" } == retained)
    }

    @Test("track count does not expand event work and overflow/cancellation stay explicit", .timeLimit(.minutes(1)))
    func boundedWork() async throws {
        let fixture = try await prepared()
        let input = try #require(fixture.request.initialSnapshot)
        let router = PhysicalDesignSourceRouter()
        let original = try router.route(input, configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        var huge = input
        huge.implementationState?.tracks[0].count = .max
        huge.implementationState?.tracks[1].count = .max
        let expanded = try router.route(huge, configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        #expect(expanded.checks == original.checks && expanded.structuralCeiling == original.structuralCeiling)
        #expect(expanded.snapshot.routes == original.snapshot.routes)
        var overflow = input
        overflow.core = .init(x: .max - 10, y: 0, width: 100, height: 100)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) { try router.route(overflow, configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry) }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await PhysicalDesignNativeMutationEngine().applyPrepared(fixture.request, to: input, processGeometry: fixture.geometry)
        }
        task.cancel()
        #expect(await task.value.status == .cancelled)
        // Source edge spacing owns contact legality even when a center-distance estimate would pass.
        let first = PhysicalDesignSnapshot.Via(id: "a", netID: "N", x: 2500, y: 2500, lowerLayer: 2, upperLayer: 3, master: "hv")
        var second = first; second.id = "b"; second.x += 99
        #expect(throws: PhysicalDesignTechnologyError.self) { try fixture.geometry.validateRoutingCuts([first, second]) }
        second.x += 1
        try fixture.geometry.validateRoutingCuts([first, second])
        let sourceCut = try fixture.geometry.viaShapes(master: "hv", x: first.x, y: first.y).filter { $0.layer == 4 }
        #expect(try !fixture.geometry.routingCutsFit(first, against: [], sourceCuts: sourceCut))
        #expect(try fixture.geometry.routingCutsFit(second, against: [], sourceCuts: sourceCut))
    }

    @Test("ECO preserves qualified unselected geometry and source clearance dominates a lower caller value", .timeLimit(.minutes(1)))
    func retainedGeometryAndClearance() async throws {
        let fixture = try await prepared()
        var request = fixture.request
        request.runID = "routing-preserved"; request.stage = .timingECO
        request.configuration.ecoAction = .rerouteNet; request.configuration.ecoTargetNetID = "N"
        request.configuration.implementationConstraints?.routeSpacing = 0
        let preserved = PhysicalDesignSnapshot.Route(id: "keep", netID: "M", segments: [.init(id: "keep-h", layer: 2, x1: 8300, y1: 9100, x2: 8700, y2: 9100, widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))])
        let contact = PhysicalDesignSnapshot.Via(id: "keep-via", netID: "M", x: 8500, y: 9100, lowerLayer: 2, upperLayer: 3, master: "hv")
        request.initialSnapshot?.nets.append(.init(id: "M", pinIDs: []))
        request.initialSnapshot?.routes = [preserved]; request.initialSnapshot?.vias = [contact]
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await fixture.store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        #expect(output.routes.first { $0.netID == "M" } == preserved && output.vias.first { $0.netID == "M" } == contact)
        let callerZero = try PhysicalDesignSourceRouter().route(try #require(fixture.request.initialSnapshot), configuration: request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        let callerSource = try PhysicalDesignSourceRouter().route(try #require(fixture.request.initialSnapshot), configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        #expect(callerZero.snapshot.routes == callerSource.snapshot.routes && callerZero.snapshot.vias == callerSource.snapshot.vias)
    }

    @Test("actual CLI completes exact routed JSON and DEF or exits blocked with no artifacts", .timeLimit(.minutes(1)), arguments: [(false, "valid"), (true, "valid"), (false, "spacing-table"), (false, "spacing-table-polygon"), (true, "spacing-table-polygon"), (false, "spacing-table-source-violation"), (false, "manufacturing-grid"), (false, "manufacturing-grid-output"), (false, "minimum-area-repair"), (false, "minimum-area-table"), (false, "minimum-area-impossible")])
    func routingCLI(_ scenario: (Bool, String)) async throws {
        let exhausted = scenario.0
        let fixture = try await prepared(scenario.1)
        var request = fixture.request
        if exhausted { request.configuration.maximumRoutingCandidateChecks = 1 }
        let root = FileManager.default.temporaryDirectory.appending(path: "source-routing-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("CLI cleanup failed: \(error)") } }
        for binding in request.inputBindings {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fixture.store.read(binding).write(to: url)
        }
        let codec = PhysicalDesignJSONCodec(), requestURL = root.appending(path: "request.json"), resultURL = root.appending(path: "result.json")
        try codec.encode(request).write(to: requestURL)
        #expect(FileManager.default.createFile(atPath: resultURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: resultURL)
        defer { do { try handle.close() } catch { Issue.record("CLI close failed: \(error)") } }
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", requestURL.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        process.waitUntilExit()
        let result = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: resultURL))
        if exhausted || scenario.1 == "spacing-table-source-violation" || scenario.1 == "manufacturing-grid-output" || scenario.1 == "minimum-area-impossible" {
            #expect(process.terminationStatus != 0 && result.status == .blocked && result.artifactBindings.isEmpty)
            let code = exhausted ? "routing_candidate_budget_exhausted" : (scenario.1 == "minimum-area-impossible" ? "routing_minimum_area_unrepairable" : (scenario.1 == "manufacturing-grid-output" ? "routing_source_geometry_invalid" : "routing_final_spacing_invalid"))
            #expect(result.diagnostics.contains { $0.code.rawValue == code }, "\(result.diagnostics)")
            if scenario.1 == "manufacturing-grid-output" { #expect(result.diagnostics.contains { $0.summary.contains("MANUFACTURINGGRID") }) }
        } else {
            #expect(process.terminationStatus == 0 && result.status == .completed, "\(result.diagnostics)")
            let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
            let output = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
            try verify(output, input: try #require(request.initialSnapshot), geometry: fixture.geometry)
            if scenario.1 == "minimum-area-repair" || scenario.1 == "minimum-area-table" {
                #expect(output.routes.flatMap(\.segments).contains { ($0.endpointExtensions?.beginDBU ?? 0) > 50 || ($0.endpointExtensions?.endDBU ?? 0) > 50 })
            }
            let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
            try verifyDEF(await store.read(def), snapshot: output, geometry: fixture.geometry)
            for binding in result.artifactBindings { _ = try await store.read(binding) }
        }
    }

    @Test("AREA refuses unowned mutation and never repairs an unselected net", .timeLimit(.minutes(1)))
    func areaOwnership() async throws {
        let fixture = try await prepared("minimum-area-repair")
        var request = fixture.request
        request.runID = "area-unowned-fill"; request.stage = .fillInsertion
        let unsupported = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request)
        #expect(unsupported.status == .blocked && unsupported.artifactBindings.isEmpty)
        #expect(unsupported.diagnostics.contains { $0.summary.contains("AREA") }, "\(unsupported.diagnostics)")
        request.stage = .timingECO; request.runID = "area-unselected-retained"
        request.configuration.ecoAction = .rerouteNet; request.configuration.ecoTargetNetID = "N"
        request.initialSnapshot?.nets.append(.init(id: "M", pinIDs: []))
        let retained = PhysicalDesignSnapshot.Route(id: "retained-M", netID: "M", segments: [.init(id: "short-M", layer: 2,
            x1: 7000, y1: 8100, x2: 7200, y2: 8100, widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))])
        request.initialSnapshot?.routes = [retained]
        let rejected = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request)
        #expect(rejected.status == .blocked && rejected.artifactBindings.isEmpty)
        #expect(rejected.diagnostics.contains { $0.code.rawValue == "routing_retained_minimum_area_invalid" }, "\(rejected.diagnostics)")
        #expect(request.initialSnapshot?.routes == [retained])
    }

    @Test("AREA search and geometry share one exact caller budget", .timeLimit(.minutes(1)))
    func areaCumulativeBudget() async throws {
        let fixture = try await prepared("minimum-area-repair")
        let snapshot = try #require(fixture.request.initialSnapshot)
        let router = PhysicalDesignSourceRouter()
        let measured = try router.route(snapshot, configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        var configuration = fixture.request.configuration
        configuration.maximumRoutingCandidateChecks = measured.checks
        let exact = try router.route(snapshot, configuration: configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        #expect(exact.checks == measured.checks && exact.snapshot.routes == measured.snapshot.routes)
        configuration.maximumRoutingCandidateChecks = measured.checks - 1
        do {
            _ = try router.route(snapshot, configuration: configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
            Issue.record("AREA search ignored the cumulative caller budget")
        } catch let error as PhysicalDesignSourceRouter.Failure {
            #expect(error.code == "routing_candidate_budget_exhausted")
        }
    }

    private func verifyAreaReference(_ snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws {
        for net in snapshot.nets {
            for (layer, rule) in geometry.routingMinimumAreas {
                var material = Region(layer: layer), routed = Region(layer: layer)
                for route in snapshot.routes where route.netID == net.id {
                    for segment in route.segments where segment.layer == Int(layer) {
                        let wire = try PhysicalDesignSourceRouter.conductor(segment, width: #require(segment.widthDBU))
                        material = try material.union(wire); routed = try routed.union(wire)
                    }
                }
                for via in snapshot.vias where via.netID == net.id {
                    for shape in try geometry.viaShapes(master: #require(via.master), x: via.x, y: via.y) where shape.layer == layer {
                        let piece = Region(layer: layer, polygons: [shape])
                        material = try material.union(piece); routed = try routed.union(piece)
                    }
                }
                for pin in snapshot.pins where pin.netID == net.id {
                    if let cellID = pin.cellID, let cell = snapshot.cells.first(where: { $0.id == cellID }) {
                        for shape in try geometry.pinShapes(master: cell.master, pin: pin.name, orientation: cell.orientation, x: cell.x, y: cell.y) where shape.layer == layer {
                            material = try material.union(Region(layer: layer, polygons: [shape]))
                        }
                    }
                }
                for component in material.connectedComponents() where try !component.intersection(routed).isEmpty {
                    #expect(component.area >= 0 && UInt64(component.area) >= rule.minimumDBU2,
                        "Independent boolean/flood connectivity AREA net \(net.id) layer \(layer)")
                }
            }
        }
    }

    private func verify(_ output: PhysicalDesignSnapshot, input: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws {
        try geometry.validate(output)
        try verifyAreaReference(output, geometry: geometry)
        #expect(output.cells == input.cells && output.nets == input.nets)
        #expect(output.processManifest == geometry.manifestReference && output.processAssets == geometry.sources)
        #expect(output.pins.map(\.id) == input.pins.map(\.id) && output.pins.map(\.netID) == input.pins.map(\.netID))
        #expect(!output.routes.isEmpty && !output.vias.isEmpty)
        #expect(output.routes.flatMap(\.segments).allSatisfy { $0.widthDBU == 100 })
        for pin in output.pins {
            let cell = try #require(output.cells.first { $0.id == pin.cellID })
            let layer = try #require(pin.accessLayer)
            let area = Region(layer: Int16(layer), polygons: try geometry.pinShapes(master: cell.master, pin: pin.name, orientation: cell.orientation, x: cell.x, y: cell.y).filter { Int($0.layer) == layer })
            #expect(try PhysicalDesignSourceRouter.cap(x: pin.x, y: pin.y, width: 100, layer: layer).subtracting(area).isEmpty)
        }
        for segment in output.routes.flatMap(\.segments) {
            let wire = try PhysicalDesignSourceRouter.conductor(segment, width: 100)
            for cell in output.cells {
                let obs = Region(layer: Int16(segment.layer), polygons: try geometry.obstructionShapes(master: cell.master, orientation: cell.orientation, x: cell.x, y: cell.y).filter { Int($0.layer) == segment.layer })
                #expect(try wire.intersection(obs).isEmpty)
            }
            for blockage in output.blockages {
                let polygon = rectangle(blockage, layer: Int16(segment.layer))
                #expect(try wire.intersection(Region(layer: Int16(segment.layer), polygons: [polygon])).isEmpty)
            }
        }
        var conductors: [(layer: Int16, region: Region, contact: String?)] = []
        for segment in output.routes.flatMap(\.segments) { conductors.append((Int16(segment.layer), try PhysicalDesignSourceRouter.conductor(segment, width: 100), nil)) }
        var terminalIndices: [Int] = []
        for pin in output.pins {
            let cell = try #require(output.cells.first { $0.id == pin.cellID }), layer = try #require(pin.accessLayer)
            terminalIndices.append(conductors.count)
            conductors.append((Int16(layer), Region(layer: Int16(layer), polygons: try geometry.pinShapes(master: cell.master, pin: pin.name, orientation: cell.orientation, x: cell.x, y: cell.y).filter { Int($0.layer) == layer }), nil))
        }
        for via in output.vias {
            let shapes = try geometry.viaShapes(master: try #require(via.master), x: via.x, y: via.y)
            for layer in [via.lowerLayer, via.upperLayer] {
                let metal = Region(layer: Int16(layer), polygons: shapes.filter { Int($0.layer) == layer })
                conductors.append((Int16(layer), metal, via.id))
                let wires = try output.routes.flatMap(\.segments).filter { $0.layer == layer }.map { try PhysicalDesignSourceRouter.conductor($0, width: 100) }
                let terminalPorts = try output.pins.filter { $0.netID == via.netID && $0.accessLayer == layer }.map { pin -> Region in
                    let cell = try #require(output.cells.first { $0.id == pin.cellID })
                    return Region(layer: Int16(layer), polygons: try geometry.pinShapes(master: cell.master, pin: pin.name, orientation: cell.orientation, x: cell.x, y: cell.y).filter { Int($0.layer) == layer })
                }
                #expect(try (wires + terminalPorts).contains { try !metal.intersection($0).isEmpty })
            }
        }
        var reached: Set<Int> = [terminalIndices[0]], frontier = [terminalIndices[0]], cursor = 0
        while cursor < frontier.count {
            let index = frontier[cursor]; cursor += 1
            for next in conductors.indices where !reached.contains(next) {
                let a = conductors[index], b = conductors[next]
                let fixedContact = a.contact != nil && a.contact == b.contact
                let metalContact = try a.layer == b.layer && !a.region.intersection(b.region).isEmpty
                if fixedContact || metalContact { reached.insert(next); frontier.append(next) }
            }
        }
        #expect(terminalIndices.allSatisfy { reached.contains($0) })
        #expect(reached.count == conductors.count)
    }

    private func verifyDEF(_ bytes: Data, snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws {
        let document = try DEFLibraryReader.read(bytes)
        #expect(document.designName == snapshot.topCell && document.dbuPerMicron == Double(snapshot.unitsPerMicron))
        let net = try #require(document.nets.first { $0.name == "N" })
        #expect(Set(net.connections.map { "\($0.componentName)/\($0.pinName)" }) == ["U1/Y", "U2/A"])
        #expect(net.routing.count == snapshot.routes.flatMap(\.segments).count + snapshot.vias.count)
        var canonical: [Int16: Region] = [:], standard: [Int16: Region] = [:]
        func merge(_ region: Region, into regions: inout [Int16: Region]) throws {
            regions[region.layer] = try (regions[region.layer] ?? Region(layer: region.layer)).union(region)
        }
        for segment in snapshot.routes.flatMap(\.segments) { try merge(PhysicalDesignSourceRouter.conductor(segment, width: try #require(segment.widthDBU)), into: &canonical) }
        for via in snapshot.vias {
            for shape in try geometry.viaShapes(master: try #require(via.master), x: via.x, y: via.y) { try merge(Region(layer: shape.layer, polygons: [shape]), into: &canonical) }
        }
        for route in net.routing {
            let layer = try #require(geometry.layers.first { $0.value.name == route.layerName }?.key)
            if let name = route.viaName {
                #expect(route.points.count == 1)
                let point = try #require(route.points.first)
                for shape in try geometry.viaShapes(master: name, x: Int64(point.x), y: Int64(point.y)) { try merge(Region(layer: shape.layer, polygons: [shape]), into: &standard) }
            } else {
                #expect(route.points.count == 2)
                #expect(route.pointExtensions.count == 2)
                let a = route.points[0], b = route.points[1]
                let width = try geometry.routingWidthAndSpacing(layer: Int(layer), units: snapshot.unitsPerMicron, width: 100, areaHandledSeparately: true).width
                try merge(PhysicalDesignSourceRouter.conductor(.init(id: "oracle", layer: Int(layer), x1: Int64(a.x), y1: Int64(a.y), x2: Int64(b.x), y2: Int64(b.y), widthDBU: width, endpointExtensions: .init(beginDBU: Int64(try #require(route.pointExtensions[0])), endDBU: Int64(try #require(route.pointExtensions[1])))), width: width), into: &standard)
            }
        }
        #expect(Set(standard.keys) == Set(canonical.keys))
        for (layer, region) in canonical { #expect(try region.symmetricDifference(try #require(standard[layer])).isEmpty) }
    }

    private func rectangle(_ rect: PhysicalDesignSnapshot.Rect, layer: Int16) -> IRBoundary {
        .init(layer: layer, datatype: 0, points: [.init(x: Int32(rect.x), y: Int32(rect.y)), .init(x: Int32(rect.maxX), y: Int32(rect.y)), .init(x: Int32(rect.maxX), y: Int32(rect.maxY)), .init(x: Int32(rect.x), y: Int32(rect.maxY)), .init(x: Int32(rect.x), y: Int32(rect.y))])
    }

    private func prepared(_ scenario: String = "valid") async throws -> RoutingFixture {
        let support = ProcessGeometryTests()
        let area = scenario.hasPrefix("minimum-area")
        let threshold = scenario == "minimum-area-impossible" ? "100" : (scenario == "minimum-area" ? "0.03" : "0.3")
        let (geometry, base, store) = try await support.fixture(scenario == "minimum-area-table" ? "spacing-table" : scenario,
            routingPorts: true, grid: scenario.hasPrefix("manufacturing-grid") || area ? "0.005" : nil, minimumArea: area ? threshold : nil)
        var request = support.nativeRequest(base)
        request.runID = "source-routing-\(scenario)"; request.stage = .globalRouting
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        snapshot.cells = [.init(id: "U1", master: "INV_X1", x: 500, y: 1000, width: 2000, height: 1000, placed: true),
            .init(id: "U2", master: "INV_X1", x: 5000, y: 3000, width: 2000, height: 1000, placed: true, orientation: .fn)]
        snapshot.pins = [.init(id: "U1/Y", cellID: "U1", name: "Y", x: 1700, y: 1100, netID: "N", direction: "output", accessLayer: 2),
            .init(id: "U2/A", cellID: "U2", name: "A", x: 6300, y: 3100, netID: "N", direction: "input", accessLayer: 2)]
        snapshot.nets = [.init(id: "N", pinIDs: ["U1/Y", "U2/A"])]
        snapshot.rows = [1000, 3000].map { .init(id: "row_\($0)", originX: 0, originY: Int64($0), siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit") }
        snapshot.blockages = [.init(x: 3000, y: 1100, width: 600, height: 2400)]
        snapshot.implementationState = .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 50), .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 25)])
        if scenario == "manufacturing-grid-output" {
            snapshot.implementationState?.tracks[0].origin = 101
            snapshot.implementationState?.tracks[1].origin = 101
        }
        try geometry.validate(snapshot)
        request.initialSnapshot = snapshot
        let design = try await store.registerInput(Data("module fixture_top(); wire N; INV_X1 U1(.Y(N)); INV_X1 U2(.A(N)); endmodule\n".utf8), relativePath: "inputs/routing.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Geometry routing; no characterized timing claim.\n".utf8), relativePath: "inputs/routing.sdc", kind: .constraint, format: .sdc)
        request = PhysicalDesignRequest(runID: request.runID, inputBindings: base.inputBindings.filter { $0.reference == base.pdk.manifest } + [design, constraints],
            design: .init(artifact: design.reference, topDesignName: base.design.topDesignName, designDigest: design.reference.digest.hexadecimalValue), constraints: constraints,
            requestedModeIDs: base.requestedModeIDs, pdk: base.pdk, stage: .globalRouting, configuration: request.configuration, initialSnapshot: snapshot, processAssets: base.processAssets)
        return .init(geometry: geometry, request: request, store: store)
    }

    @Test("splitting both retained wires cannot evade a parallel-length rule", .timeLimit(.minutes(1)))
    func splitRetainedWires() async throws {
        let fixture = try await prepared("spacing-table")
        var request = fixture.request
        request.stage = .timingECO
        request.configuration.ecoAction = .rerouteNet
        request.configuration.ecoTargetNetID = "N"
        for (name, y) in [("M", Int64(8100)), ("P", Int64(8300))] {
            request.initialSnapshot?.nets.append(.init(id: name, pinIDs: []))
            request.initialSnapshot?.routes.append(.init(id: "retained_\(name)", netID: name, segments: [
                .init(id: "\(name)_1", layer: 2, x1: 500, y1: y, x2: 1000, y2: y,
                      widthDBU: 100, endpointExtensions: .init(beginDBU: 0, endDBU: 0)),
                .init(id: "\(name)_2", layer: 2, x1: 1000, y1: y, x2: 1500, y2: y,
                      widthDBU: 100, endpointExtensions: .init(beginDBU: 0, endDBU: 0))
            ], defStatus: .routed))
        }
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty)
        #expect(result.diagnostics.contains { $0.code.rawValue == "routing_final_spacing_invalid" })
    }
    @Test("OBS policy reaches actual API and CLI retained-metal replay and readback", arguments: ["obs-default", "obs-on", "obs-off", "obs-pin"])
    func obstructionPolicy(_ scenario: String) async throws {
        let fixture = try await prepared(scenario)
        var request = fixture.request
        request.stage = .timingECO
        request.configuration.ecoAction = .rerouteNet
        request.configuration.ecoTargetNetID = "N"
        let retained = PhysicalDesignSnapshot.Route(id: "retained-M", netID: "M", segments: [
            .init(id: "M-h", layer: 2, x1: 600, y1: 4700, x2: 1400, y2: 4700,
                widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))], defStatus: .routed)
        request.initialSnapshot?.nets.append(.init(id: "M", pinIDs: []))
        request.initialSnapshot?.routes = [retained]
        let root = FileManager.default.temporaryDirectory.appending(path: "obs-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in request.inputBindings + Array(request.processAssets.values) {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fixture.store.read(binding).write(to: url)
        }
        let fileStore = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        for cli in [false, true] {
            request.runID = "obs-\(scenario)-\(cli)"
            let result: PhysicalDesignResult
            if cli { result = try await invokeObstructionCLI(request, root: root) }
            else { result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request) }
            let store: any PhysicalDesignArtifactStore = cli ? fileStore : fixture.store
            if scenario == "obs-off" || scenario == "obs-pin" {
                #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
                #expect(result.diagnostics.contains { $0.code.rawValue == "routing_final_spacing_invalid" }, "\(result.diagnostics)")
                continue
            }
            #expect(result.status == .completed, "\(result.diagnostics)")
            let reference = try #require(result.payload.physicalDesign)
            let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
            #expect(output.routes.first { $0.netID == "M" } == retained)
            #expect(output.processAssets == request.processAssets.mapValues(\.reference))
            try fixture.geometry.validate(output)
            let def = try DEFLibraryReader.read(await store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })))
            #expect(def.nets.contains { $0.name == "M" && !$0.routing.isEmpty })
            var resumed = request
            resumed.runID += "-resume"
            resumed.initialSnapshot = nil
            resumed.inputLayout = reference
            resumed.inputBindings.append(reference.layoutArtifact)
            resumed.inputs.append(reference.layoutArtifact.reference)
            let again: PhysicalDesignResult
            if cli { again = try await invokeObstructionCLI(resumed, root: root) }
            else { again = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(resumed) }
            #expect(again.status == .completed, "\(again.diagnostics)")
            let reread = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(try #require(again.payload.physicalDesign?.layoutArtifact)))
            #expect(reread.routes.first { $0.netID == "M" } == retained)
        }
    }

    private func invokeObstructionCLI(_ request: PhysicalDesignRequest, root: URL) async throws -> PhysicalDesignResult {
        let codec = PhysicalDesignJSONCodec(), input = root.appending(path: request.runID + ".json")
        let output = root.appending(path: request.runID + "-result.json")
        try codec.encode(request).write(to: input)
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { do { try handle.close() } catch { Issue.record(error) } }
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", input.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        let result = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: output))
        #expect((process.terminationStatus == 0) == (result.status == .completed))
        return result
    }

    @Test func conflictingObstructionPoliciesAreRejected() async throws {
        let (request, store) = try await ProcessGeometryTests().fixtureSources("obs-conflict", routingPorts: true)
        await #expect(throws: PhysicalDesignTechnologyError.self) {
            _ = try await PhysicalDesignProcessInputs.load(request: request, store: store)
        }
        var native = ProcessGeometryTests().nativeRequest(request)
        let design = try await store.registerInput(Data("module fixture_top(); endmodule".utf8), relativePath: "inputs/policy.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Policy admission".utf8), relativePath: "inputs/policy.sdc", kind: .constraint, format: .sdc)
        native.design.artifact = design.reference
        native.design.designDigest = design.reference.digest.hexadecimalValue
        native.constraints = constraints
        native.inputBindings = native.inputBindings.filter { $0.reference == native.pdk.manifest } + [design, constraints] + native.processAssets.values.sorted { $0.path < $1.path }
        native.inputs = native.inputBindings.map(\.reference)
        let root = FileManager.default.temporaryDirectory.appending(path: "obs-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in native.inputBindings {
            let url = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await store.read(binding).write(to: url)
        }
        for cli in [false, true] {
            native.runID = "obs-conflict-\(cli)"
            let result: PhysicalDesignResult
            if cli { result = try await invokeObstructionCLI(native, root: root) }
            else { result = try await PhysicalDesignEngine(artifactStore: store).execute(native) }
            #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
            #expect(result.diagnostics.contains { $0.summary.contains("USEMINSPACING") }, "\(result.diagnostics)")
        }
    }

    private struct RoutingFixture {
        let geometry: PhysicalDesignProcessGeometry
        let request: PhysicalDesignRequest
        let store: InMemoryPhysicalDesignArtifactStore
    }

}
