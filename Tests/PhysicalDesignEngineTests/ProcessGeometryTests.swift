import Foundation
import Testing
import CircuiteFoundation
import DEF
import LEF
import LayoutIR
import MaskGeometry
import PDKCore
import PhysicalDesignEngine
import Synchronization
@testable import PhysicalDesignCore

@Suite("Exact native process geometry projection")
struct ProcessGeometryTests {
    @Test("source-bound geometry preserves origin and all standard orientations")
    func projectedGeometry() async throws {
        let (geometry, request, _) = try await fixture()
        #expect(geometry.manifestReference == request.pdk.manifest)
        #expect(geometry.sources == request.processAssets.mapValues(\.reference))
        let master = try geometry.requireMaster("INV_X1")
        #expect(master.width == 2000 && master.height == 1000)
        #expect(master.origin == IRPoint(x: 100, y: -200))
        #expect(master.pins["Y"]?.definition.direction == .output)
        #expect(master.pins["Y"]?.definition.use == .signal)
        #expect(master.pins["A"]?.shapes.first?.points.count == 7)
        #expect(geometry.sites["unit"]?.width == 100)
        #expect(geometry.sites["unit"]?.height == 1000)
        let via = try #require(geometry.vias["hv"])
        #expect(via.lowerLayer == 2 && via.cutLayer == 4 && via.upperLayer == 3)
        #expect(via.shapes.map(\.layer) == [2, 4, 3])
        #expect(via.definition.resistance == 0.75)
        let expected: [(DEFOrientation, Int32, Int32, Int32, Int32)] = [
            (.n, 10200, 20100, 10400, 20300), (.s, 11600, 20700, 11800, 20900),
            (.w, 10700, 20200, 10900, 20400), (.e, 10100, 21600, 10300, 21800),
            (.fn, 11600, 20100, 11800, 20300), (.fs, 10200, 20700, 10400, 20900),
            (.fw, 10100, 20200, 10300, 20400), (.fe, 10700, 21600, 10900, 21800)
        ]
        for (orientation, minX, minY, maxX, maxY) in expected {
            let shape = try #require(try geometry.pinShapes(master: "INV_X1", pin: "Y", orientation: orientation, x: 10000, y: 20000).first)
            let bounds = try #require(PolygonGeometry.boundingBox(of: shape.points))
            #expect(bounds.minX == minX && bounds.minY == minY && bounds.maxX == maxX && bounds.maxY == maxY)
            #expect(shape.layer == 2)
        }
        let obstructions = try geometry.obstructionShapes(master: "INV_X1", orientation: .n, x: 10000, y: 20000)
        #expect(obstructions.count == 1 && obstructions[0].layer == 3)
        let polygon = try #require(try geometry.pinShapes(master: "INV_X1", pin: "A", orientation: .n, x: 10000, y: 20000).first)
        let region = Region(layer: polygon.layer, polygons: [polygon])
        #expect(region.contains(.init(x: 10250, y: 20050)))
        #expect(!region.contains(.init(x: 10400, y: 20200)))
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try geometry.pinShapes(master: "INV_X1", pin: "Y", orientation: .n, x: .max, y: 0)
        }
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try geometry.pinShapes(master: "INV_X1", pin: "missing", orientation: .n, x: 0, y: 0)
        }
    }

    @Test("PORT VIA expands the exact fixed stack")
    func portVia() async throws {
        let (geometry, _, _) = try await fixture("port-via")
        let shapes = try geometry.pinShapes(master: "INV_X1", pin: "Y", orientation: .n, x: 0, y: 0)
        #expect(shapes.map(\.layer) == [2, 4, 3])
        let cut = try #require(shapes.first { $0.layer == 4 })
        let bounds = try #require(PolygonGeometry.boundingBox(of: cut.points))
        #expect(bounds.minX == 275 && bounds.minY == 175 && bounds.maxX == 325 && bounds.maxY == 225)
    }

    @Test("invalid process geometry never becomes a projected catalogue", arguments: [
        "unmapped-master", "unmapped-layer", "ambiguous-layer", "missing-site", "duplicate-site",
        "duplicate-master", "duplicate-pin", "missing-pin-port", "sub-dbu", "sub-dbu-origin",
        "shape-range", "zero-rectangle", "diagonal-polygon", "crossing-polygon", "empty-via-layer",
        "wrong-cut-layer", "wrong-lef-cut-type", "missing-port-via", "generated-via", "mask", "bad-resistance"
    ])
    func invalidProjection(scenario: String) async throws {
        await #expect(throws: PhysicalDesignTechnologyError.self) {
            try await fixture(scenario)
        }
    }

    @Test("native floorplan placement and resume retain exact cell and pin sources")
    func nativeConsumption() async throws {
        let (geometry, base, store) = try await fixture()
        let request = nativeRequest(base)
        let engine = PhysicalDesignEngine(artifactStore: store)
        let result = try await engine.execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let reference = try #require(result.payload.physicalDesign)
        #expect(reference.layoutArtifact.descriptor.format == .json)
        let codec = PhysicalDesignJSONCodec()
        let floorplan = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
        #expect(floorplan.processManifest == geometry.manifestReference)
        #expect(floorplan.processAssets == geometry.sources)
        #expect(floorplan.rows.allSatisfy { $0.siteName == "unit" && $0.siteWidth == 100 && $0.height == 1000 })
        var placement = resumed(request, from: reference, runID: "place-exact", stage: .placement)
        let placedResult = try await engine.execute(placement)
        #expect(placedResult.status == .completed, "\(placedResult.diagnostics)")
        let placedReference = try #require(placedResult.payload.physicalDesign)
        let placed = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(placedReference.layoutArtifact))
        let cell = try #require(placed.cells.first)
        let pin = try #require(placed.pins.first)
        #expect(cell.orientation == .fn && cell.x == 0 && cell.y == 0 && cell.placed)
        #expect(pin.x == 1700 && pin.y == 200 && pin.accessLayer == 2)
        try geometry.validate(placed)
        let diffBinding = try #require(placedResult.payload.designDiff)
        let diff = try codec.decode(PhysicalDesignDesignDiff.self, from: await store.read(diffBinding))
        #expect(Set(diff.changes.map(\.path)).isSuperset(of: ["/cells", "/pins"]))
        let defBinding = try #require(placedResult.artifactBindings.first { $0.descriptor.format == .def })
        let def = try #require(String(data: await store.read(defBinding), encoding: .utf8))
        #expect(def.contains("ROW row_0 unit 0 0 N DO 100 BY 1 STEP 100 0"))
        #expect(def.contains("PLACED ( 0 0 ) FN"))
        #expect(def.contains("LAYER metH") && !def.contains("LAYER M2"))
        let replay = try await engine.execute(resumed(placement, from: placedReference, runID: "replay-exact", stage: .placement))
        #expect(replay.status == .completed, "\(replay.diagnostics)")
        placement = resumed(request, from: placedReference, runID: "omitted-source", stage: .placement, processAssets: [:])
        let omitted = try await engine.execute(placement)
        #expect(omitted.status == .blocked && omitted.artifactBindings.isEmpty)
        #expect(omitted.diagnostics.contains { $0.code.rawValue == "physical_technology_invalid" })
        let bare = await PhysicalDesignNativeMutationEngine().apply(request, to: floorplan)
        #expect(bare.status == .blocked && bare.diagnostics.contains { $0.code.rawValue == "process_geometry_unresolved" })
        var movement = resumed(request, from: placedReference, runID: "move-exact", stage: .timingECO)
        movement.configuration.ecoAction = .moveCell
        movement.configuration.ecoTargetCellID = "U1"
        movement.configuration.ecoDeltaX = 300
        let movedResult = try await engine.execute(movement)
        #expect(movedResult.status == .completed, "\(movedResult.diagnostics)")
        let movedBinding = try #require(movedResult.payload.physicalDesign?.layoutArtifact)
        let moved = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(movedBinding))
        #expect(moved.cells.first?.x == 300 && moved.pins.first?.x == 2000 && moved.pins.first?.y == 200)
        #expect(moved.implementationState?.placementProof == nil)
        try geometry.validate(moved)
        var resize = resumed(request, from: placedReference, runID: "fabricated-resize", stage: .timingECO)
        resize.configuration.ecoTargetCellID = "U1"
        let rejectedResize = try await engine.execute(resize)
        #expect(rejectedResize.status == .blocked && rejectedResize.artifactBindings.isEmpty)
        #expect(rejectedResize.diagnostics.contains { $0.code.rawValue == "eco_replacement_master_missing" })
        #expect(await store.data(at: "runs/fabricated-resize/physical-design/timingECO/revision.json") == nil)
        #expect(throws: PhysicalDesignDEFExportError.unresolvedProcessSources) { try PhysicalDesignDEFWriter().write(placed) }
        var changed = placed
        changed.processAssets["cells"] = request.processAssets["tech"]?.reference
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.bind(changed) }
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.validate(changed) }

        let cellBinding = try #require(request.processAssets["cells"])
        let changedCellData = Data(try #require(String(data: await store.read(cellBinding), encoding: .utf8)).replacingOccurrences(of: "SIZE 2 BY 1", with: "SIZE 3 BY 1").utf8)
        let changedCell = try await store.registerInput(changedCellData, relativePath: "inputs/changed-cells.lef", kind: .technology, format: .lef)
        let manifestBinding = try #require(request.inputBindings.first { $0.reference == request.pdk.manifest })
        var manifest = try PDKManifestCodec.decode(data: await store.read(manifestBinding))
        let assetIndex = try #require(manifest.assets.firstIndex { $0.assetID == "cells" })
        manifest.assets[assetIndex].sha256 = changedCell.reference.digest.hexadecimalValue
        manifest.assets[assetIndex].byteCount = Int64(changedCellData.count)
        let changedManifest = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/changed-process.json", kind: .technology, format: .json)
        let changedRequest = PhysicalDesignRequest(runID: "changed-source", inputBindings: [changedManifest, placedReference.layoutArtifact] + request.inputBindings.filter { $0.reference == request.design.artifact || $0.reference == request.constraints.reference },
            design: request.design, constraints: request.constraints, requestedModeIDs: request.requestedModeIDs,
            pdk: .init(manifest: changedManifest.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: changedManifest),
                processID: request.pdk.processID, version: request.pdk.version, digest: changedManifest.reference.digest.hexadecimalValue),
            inputLayout: placedReference, stage: .placement, configuration: request.configuration,
            processAssets: ["cells": changedCell, "tech": try #require(request.processAssets["tech"])])
        let changedResult = try await engine.execute(changedRequest)
        #expect(changedResult.status == .blocked && changedResult.artifactBindings.isEmpty)
        #expect(changedResult.diagnostics.contains { $0.summary.contains("same manifest") })
    }

    @Test("explicit replacement adopts exact source SIZE and reconstructs connected ports", arguments: [
        "valid", "same-master", "ports", "direction", "use", "height", "symmetry", "missing-name", "unknown", "locked", "collision"
    ])
    func exactReplacement(scenario: String) async throws {
        let (geometry, base, store) = try await fixture(replacement: scenario)
        let engine = PhysicalDesignEngine(artifactStore: store)
        let request = nativeRequest(base)
        let floorplanned = try #require(try await engine.execute(request).payload.physicalDesign)
        let placed = try #require(try await engine.execute(resumed(request, from: floorplanned, runID: "replacement-place", stage: .placement)).payload.physicalDesign)
        let codec = PhysicalDesignJSONCodec()
        var input = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(placed.layoutArtifact))
        input.pins[0].netID = "N"
        input.nets = [.init(id: "N", pinIDs: [input.pins[0].id])]
        if scenario == "locked" { input.cells[0].locked = true }
        if scenario == "collision" {
            input.cells.append(.init(id: "U2", master: "INV_X1", x: 2500, y: 0, width: 2000, height: 1000, placed: true))
            input.implementationState?.placementProof = nil
        }
        #expect(input.validationDiagnostics().isEmpty)
        try geometry.validate(input)
        var replacement = request
        replacement.runID = "replacement-\(scenario)"
        replacement.stage = .timingECO
        replacement.initialSnapshot = input
        replacement.configuration.ecoTargetCellID = "U1"
        replacement.configuration.ecoReplacementMaster = scenario == "missing-name" ? nil : (scenario == "unknown" ? "INV_MISSING" : (scenario == "same-master" ? "INV_X1" : "INV_X2"))
        let result = try await engine.execute(replacement)
        if scenario == "valid" || scenario == "same-master" {
            #expect(result.status == .completed, "\(result.diagnostics)")
            let reference = try #require(result.payload.physicalDesign)
            let output = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
            let cell = try #require(output.cells.first)
            #expect(cell.id == input.cells[0].id && cell.orientation == .fn && cell.x == 0 && cell.y == 0)
            #expect(output.nets == input.nets)
            #expect(output.pins[0].id == input.pins[0].id && output.pins[0].netID == "N")
            if scenario == "valid" {
                #expect(cell.master == "INV_X2" && cell.width == 3000 && cell.height == 1000)
                #expect(output.pins[0].x == 2300 && output.pins[0].y == 100 && output.pins[0].accessLayer == 3)
                #expect(output.implementationState?.placementProof == nil)
            } else {
                #expect(output.cells == input.cells && output.pins == input.pins)
                #expect(output.implementationState?.placementProof == input.implementationState?.placementProof)
            }
            try geometry.validate(output)
            let encoded = try codec.encode(replacement)
            #expect(try codec.decode(PhysicalDesignRequest.self, from: encoded).configuration.ecoReplacementMaster == replacement.configuration.ecoReplacementMaster)
        } else {
            #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
            let code: String
            switch scenario {
            case "missing-name": code = "eco_replacement_master_missing"
            case "locked": code = "eco_locked_cell"
            case "collision": code = "eco_resize_illegal"
            case "height", "symmetry": code = "process_geometry_invalid"
            default: code = "eco_replacement_invalid"
            }
            #expect(result.diagnostics.contains { $0.code.rawValue == code }, "\(result.diagnostics)")
            #expect(await store.data(at: "runs/\(replacement.runID)/physical-design/timingECO/revision.json") == nil)
        }
    }

    @Test("native routing and CTS construct exact named fixed vias", arguments: [
        "routing", "clock", "eco", "power", "source-access", "vertical-access", "no-default-via", "ambiguous-default-via", "offset-via", "clock-no-default", "clock-ambiguous"
    ])
    func constructedFixedVias(scenario: String) async throws {
        let sourceScenario = scenario == "source-access" ? "port-via" : (scenario == "clock-no-default" ? "no-default-via" : (scenario == "clock-ambiguous" ? "ambiguous-default-via" : scenario))
        let (geometry, base, _) = try await fixture(sourceScenario)
        var request = nativeRequest(base)
        request.stage = scenario.hasPrefix("clock") ? .clockTreeSynthesis : .globalRouting
        if scenario == "eco" {
            request.stage = .timingECO
            request.configuration.ecoAction = .rerouteNet
            request.configuration.ecoTargetNetID = "N"
        }
        if scenario == "power" { request.stage = .powerPlanning; request.configuration.powerNetNames = ["N"] }
        request.configuration.implementationConstraints?.clockBufferDistanceThresholdDBU = .max
        request.configuration.implementationConstraints?.clockRouteLayer = 2
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        snapshot.cells = [
            .init(id: "U1", master: "INV_X1", x: 500, y: 1000, width: 2000, height: 1000, placed: true),
            .init(id: "U2", master: "INV_X1", x: 1900, y: 2000, width: 2000, height: 1000, placed: true)
        ]
        snapshot.pins = [
            .init(id: "Y", cellID: "U1", name: "Y", x: 700, y: 1100, netID: "N", direction: "output", accessLayer: 2),
            .init(id: "A", cellID: "U2", name: "A", x: 2100, y: 2000, netID: "N", direction: "input", accessLayer: 2)
        ]
        snapshot.nets = [.init(id: "N", pinIDs: ["Y", "A"], isClock: scenario.hasPrefix("clock"))]
        if scenario == "source-access" { snapshot.pins[0].accessLayer = 3 }
        if scenario == "vertical-access" {
            snapshot.cells[0].x = 700
            snapshot.cells[1].x = 700
            snapshot.pins[0].x = 900
            snapshot.pins[1].x = 900
        }
        snapshot.rows = [1000, 2000].map { y in .init(id: "row_\(y)", originX: 0, originY: Int64(y), siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit") }
        snapshot.implementationState = .init(tracks: [
            .init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 50),
            .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 25)
        ])
        try geometry.validate(snapshot)
        let mutation = PhysicalDesignNativeMutationEngine()
        let outcome = await mutation.applyPrepared(request, to: snapshot, processGeometry: geometry)
        if ["routing", "clock", "eco", "source-access", "vertical-access"].contains(scenario) {
            #expect(outcome.status == .completed, "\(outcome.diagnostics)")
            let output = try #require(outcome.snapshot)
            let via = try #require(output.vias.first)
            #expect(output.vias.count == (scenario == "source-access" ? 3 : 2))
            #expect(output.vias.allSatisfy { $0.master == "hv" && $0.lowerLayer == 2 && $0.upperLayer == 3 })
            let sourceX: Int64 = scenario == "vertical-access" ? 900 : 700
            let targetX: Int64 = scenario == "vertical-access" ? 900 : 2100
            #expect(output.vias.contains { $0.x == targetX && $0.y == 2000 })
            if scenario == "source-access" || scenario == "vertical-access" {
                #expect(output.vias.contains { $0.x == sourceX && $0.y == 1100 })
            } else { #expect(via.x == 2100 && via.y == 1100) }
            try geometry.validate(output)
            if scenario == "routing" {
                request.stage = .detailedRouting
                let detailed = await mutation.applyPrepared(request, to: output, processGeometry: geometry)
                #expect(detailed.status == .completed && detailed.snapshot?.vias == output.vias)
                request.stage = .redundantViaInsertion
                let redundant = await mutation.applyPrepared(request, to: output, processGeometry: geometry)
                #expect(redundant.status == .completed, "\(redundant.diagnostics)")
                #expect(redundant.snapshot?.vias.filter(\.isRedundant).allSatisfy { $0.master == "hv" } == true)
                try geometry.validate(try #require(redundant.snapshot))
            }
        } else {
            #expect(outcome.status == .blocked && outcome.snapshot == nil)
            #expect(outcome.diagnostics.contains { $0.code.rawValue == "native_via_source_invalid" }, "\(outcome.diagnostics)")
        }
    }

    @Test("named non-default vias retain identity and footprint bounds govern redundant candidates")
    func viaFootprintAuthority() async throws {
        let (geometry, base, _) = try await fixture("no-default-via")
        let bounds = PhysicalDesignSnapshot.Rect(x: 0, y: 0, width: 300, height: 300)
        let named = PhysicalDesignSnapshot.Via(id: "V", netID: "N", x: 100, y: 100, lowerLayer: 2, upperLayer: 3, master: "hv")
        #expect(try geometry.resolveVia(named, within: bounds).master == "hv")
        var outside = named
        outside.x = 0
        #expect(bounds.containsPoint(x: outside.x, y: outside.y))
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.resolveVia(outside, within: bounds) }
        var unnamed = named
        unnamed.master = nil
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.resolveVia(unnamed, within: bounds) }
        var snapshot = try geometry.bind(.init(topCell: base.design.topDesignName,
            die: .init(x: 0, y: 0, width: 10000, height: 10000), core: bounds, nets: [.init(id: "N", pinIDs: [])],
            routes: [.init(id: "route", netID: "N", segments: [
                .init(id: "H", layer: 2, x1: 0, y1: 100, x2: 300, y2: 100),
                .init(id: "V", layer: 3, x1: 100, y1: 0, x2: 100, y2: 300)
            ])], vias: [named]))
        var request = nativeRequest(base)
        request.stage = .redundantViaInsertion
        request.configuration.repairConstraints?.minimumViaSpacing = 200
        try geometry.validate(snapshot)
        let outcome = await PhysicalDesignNativeMutationEngine().applyPrepared(request, to: snapshot, processGeometry: geometry)
        #expect(outcome.status == .blocked && outcome.snapshot == nil)
        #expect(outcome.diagnostics.contains { $0.code.rawValue == "redundant_via_location_unavailable" })
        snapshot.vias[0].master = "missing"
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.validate(snapshot) }
    }

    @Test("contradictory canonical geometry cannot enter or leave process-bound mutation", arguments: [
        "width", "orientation-size", "missing-layer", "wrong-layer", "direction", "pin-outside", "missing-site", "site-size",
        "off-site", "missing-via", "via-layers", "via-footprint", "coordinate-overflow"
    ])
    func invalidNativeGeometry(scenario: String) async throws {
        let (geometry, base, _) = try await fixture()
        var snapshot = try geometry.bind(try #require(nativeRequest(base).initialSnapshot))
        snapshot.rows = [.init(id: "row", originX: 0, originY: 0, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit")]
        switch scenario {
        case "width": snapshot.cells[0].width = 2001
        case "orientation-size": snapshot.cells[0].orientation = .w
        case "missing-layer": snapshot.pins[0].accessLayer = nil
        case "wrong-layer": snapshot.pins[0].accessLayer = 3
        case "direction": snapshot.pins[0].direction = "input"
        case "pin-outside": snapshot.pins[0].x = snapshot.cells[0].x
        case "missing-site": snapshot.rows[0].siteName = nil
        case "site-size": snapshot.rows[0].siteWidth = 101
        case "off-site": snapshot.cells[0].placed = true; snapshot.cells[0].x += 1
        case "missing-via", "via-layers", "via-footprint":
            snapshot.nets = [.init(id: "N", pinIDs: [])]
            snapshot.vias = [.init(id: "V", netID: "N", x: scenario == "via-footprint" ? 0 : 1000, y: 1000,
                lowerLayer: 2, upperLayer: scenario == "via-layers" ? 4 : 3, master: scenario == "missing-via" ? nil : "hv")]
        case "coordinate-overflow": snapshot.cells[0].x = .max
        default: Issue.record("Unknown admission counterexample")
        }
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.validate(snapshot) }
    }

    @Test("site equivalence and macro candidates enforce the standard flipped-row combinations")
    func siteSymmetry() async throws {
        let (geometry, base, _) = try await fixture("site-y")
        var snapshot = try geometry.bind(try #require(nativeRequest(base).initialSnapshot))
        snapshot.pins = []
        snapshot.cells[0].placed = true
        snapshot.cells[0].x = 0
        snapshot.cells[0].y = 0
        for rowOrientation: DEFOrientation in [.n, .fs] {
            snapshot.rows = [.init(id: "row", originX: 0, originY: 0, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit", orientation: rowOrientation)]
            for orientation: DEFOrientation in [.n, .fn, .fs, .s] {
                snapshot.cells[0].orientation = orientation
                let legal = rowOrientation == .n ? [.n, .fn].contains(orientation) : [.fs, .s].contains(orientation)
                if legal { try geometry.validate(snapshot) }
                else { #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.validate(snapshot) } }
            }
        }
        snapshot.cells[0].placed = false
        snapshot.cells[0].orientation = .n
        snapshot.rows = [
            .init(id: "a-flipped", originX: 0, originY: 0, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit", orientation: .fs),
            .init(id: "b-normal", originX: 0, originY: 1000, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit")
        ]
        var placement = nativeRequest(base)
        placement.stage = .placement
        let outcome = await PhysicalDesignNativeMutationEngine().applyPrepared(placement, to: snapshot, processGeometry: geometry)
        #expect(outcome.status == .completed)
        #expect(outcome.snapshot?.cells.first?.y == 1000)
    }

    private func nativeRequest(_ base: PhysicalDesignRequest) -> PhysicalDesignRequest {
        var request = base
        request.initialSnapshot = .init(topCell: base.design.topDesignName, die: .init(x: 0, y: 0, width: 10000, height: 10000),
            core: .init(x: 0, y: 0, width: 10000, height: 10000),
            cells: [.init(id: "U1", master: "INV_X1", x: 500, y: 200, width: 2000, height: 1000, orientation: .fn)],
            pins: [.init(id: "U1/Y", cellID: "U1", name: "Y", x: 2200, y: 400, direction: "output", accessLayer: 2)])
        request.configuration.siteWidth = 100
        request.configuration.rowHeight = 1000
        request.configuration.implementationConstraints = .init(routeWidth: 100, routeSpacing: 100)
        request.configuration.preferredRoutingLayers = [2, 3]
        return request
    }

    @Test("fixed via footprints are admitted but incomplete standard export persists nothing")
    func fixedViaAdmissionAndExport() async throws {
        let (geometry, base, store) = try await fixture()
        var request = nativeRequest(base)
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        snapshot.nets = [.init(id: "N", pinIDs: [])]
        snapshot.vias = [.init(id: "V", netID: "N", x: 1000, y: 1000, lowerLayer: 2, upperLayer: 3, master: "hv")]
        try geometry.validate(snapshot)
        request.initialSnapshot = snapshot
        request.runID = "unsupported-via-export"
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty)
        #expect(result.diagnostics.contains { $0.code.rawValue == "physical_def_export_unsupported" })
        #expect(await store.data(at: "runs/unsupported-via-export/physical-design/floorplan/revision.json") == nil)
        #expect(throws: PhysicalDesignDEFExportError.self) { try PhysicalDesignDEFWriter().write(.empty(topCell: "empty")) }
    }

    @Test("native DEF intake resolves standard site and reflected master geometry")
    func nativeSourceDEF() async throws {
        let (_, base, store) = try await fixture()
        let data = sourceDEF()
        let binding = try await store.registerInput(data, relativePath: "inputs/source.def", kind: .layout, format: .def)
        let reference = PhysicalDesignReference(layoutArtifact: binding, topCell: "fixture_top", layoutDigest: binding.reference.digest.hexadecimalValue)
        let request = resumed(nativeRequest(base), from: reference, runID: "source-def", stage: .floorplan)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let outputBinding = try #require(result.payload.physicalDesign?.layoutArtifact)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(outputBinding))
        let row = try #require(output.rows.first)
        let cell = try #require(output.cells.first)
        let pin = try #require(output.pins.first)
        #expect(row.height == 1000 && row.siteName == "unit" && row.siteWidth == 100)
        #expect(cell.orientation == .fn && cell.locked && cell.width == 2000 && cell.height == 1000)
        #expect(pin.x == 3800 && pin.y == 3100 && pin.direction == "output" && pin.accessLayer == 2)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let projections = Mutex(0)
        let parsed = PhysicalDesignDEFParser().parseResolved(data, cellMasters: inputs.cellViews.values.flatMap(\.macros), processFactory: { units in
            projections.withLock { $0 += 1 }
            return try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: units)
        })
        #expect(parsed.result.isValid && parsed.geometry?.sources == output.processAssets)
        #expect(projections.withLock { $0 } == 1)
    }

    @Test("source-bound DEF rejects semantic loss and unresolved physical references", arguments: [
        "missing-version", "version-loss", "missing-units", "malformed-units", "late-units", "duplicate-design", "die-overflow", "missing-site", "row-array", "site-step", "row-overflow", "row-union-overflow",
        "unknown-master", "unknown-pin", "bad-orientation", "cover", "component-attribute", "unknown-header",
        "net-power", "duplicate-connection", "route", "top-ports", "special-nets", "routing-blockage", "bad-track",
        "multiple-track-layers", "missing-end", "trailing-input"
    ])
    func sourceDEFFailures(scenario: String) async throws {
        let (_, request, store) = try await fixture()
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        var source = try #require(String(data: sourceDEF(), encoding: .utf8))
        switch scenario {
        case "missing-version": source = source.replacingOccurrences(of: "VERSION 5.8 ;", with: "")
        case "version-loss": source = source.replacingOccurrences(of: "VERSION 5.8 ;", with: "VERSION 5.8 UNKNOWN ;")
        case "missing-units": source = source.replacingOccurrences(of: "UNITS DISTANCE MICRONS 1000 ;", with: "")
        case "malformed-units": source = source.replacingOccurrences(of: "UNITS DISTANCE MICRONS", with: "UNITS UNKNOWN MICRONS")
        case "duplicate-design": source = source.replacingOccurrences(of: "DESIGN fixture_top ;", with: "DESIGN other ;\nDESIGN fixture_top ;")
        case "die-overflow": source = source.replacingOccurrences(of: "( 0 0 ) ( 10000 10000 )", with: "( -9000000000000000000 0 ) ( 9000000000000000000 10000 )")
        case "late-units": source = source.replacingOccurrences(of: "UNITS DISTANCE MICRONS 1000 ;", with: "").replacingOccurrences(of: "COMPONENTS 1", with: "UNITS DISTANCE MICRONS 1000 ;\nCOMPONENTS 1")
        case "missing-site": source = source.replacingOccurrences(of: "row unit", with: "row missing")
        case "row-array": source = source.replacingOccurrences(of: "BY 1 STEP", with: "BY 2 STEP")
        case "site-step": source = source.replacingOccurrences(of: "STEP 100 0", with: "STEP 200 0")
        case "row-overflow": source = source.replacingOccurrences(of: "unit 0 3000", with: "unit 9223372036854775807 3000")
        case "row-union-overflow": source = source.replacingOccurrences(of: "ROW row unit 0 3000 N DO 100 BY 1 STEP 100 0 ;", with: "ROW a unit -9000000000000000000 3000 N DO 1 BY 1 STEP 100 0 ;\nROW b unit 9000000000000000000 3000 N DO 1 BY 1 STEP 100 0 ;")
        case "unknown-master": source = source.replacingOccurrences(of: "U1 INV_X1", with: "U1 unknown")
        case "unknown-pin": source = source.replacingOccurrences(of: "U1 Y", with: "U1 missing")
        case "bad-orientation": source = source.replacingOccurrences(of: ") FN", with: ") unknown")
        case "cover": source = source.replacingOccurrences(of: "FIXED", with: "COVER")
        case "component-attribute": source = source.replacingOccurrences(of: ") FN ;", with: ") FN + SOURCE USER ;")
        case "unknown-header": source = source.replacingOccurrences(of: "COMPONENTS 1", with: "GCELLGRID X 0 DO 2 STEP 100 ;\nCOMPONENTS 1")
        case "net-power": source = source.replacingOccurrences(of: "( U1 Y ) ;", with: "( U1 Y ) + USE POWER ;")
        case "duplicate-connection": source = source.replacingOccurrences(of: "( U1 Y ) ;", with: "( U1 Y ) ( U1 Y ) ;")
        case "route": source = source.replacingOccurrences(of: "( U1 Y ) ;", with: "( U1 Y ) + ROUTED metH ( 3800 3100 ) ( 5000 3100 ) ;")
        case "top-ports": source = source.replacingOccurrences(of: "NETS 1 ;", with: "PINS 1 ;\n- P + NET N + DIRECTION INPUT + LAYER metH ( -50 -50 ) ( 50 50 ) + PLACED ( 5000 3100 ) N ;\nEND PINS\nNETS 1 ;")
        case "special-nets": source = source.replacingOccurrences(of: "NETS 1 ;", with: "SPECIALNETS 1 ;\n- VDD + USE POWER + ROUTED metH 100 ( 0 100 ) ( 1000 100 ) ;\nEND SPECIALNETS\nNETS 1 ;")
        case "routing-blockage": source = source.replacingOccurrences(of: "NETS 1 ;", with: "BLOCKAGES 1 ;\n- LAYER metH RECT ( 0 0 ) ( 100 100 ) ;\nEND BLOCKAGES\nNETS 1 ;")
        case "bad-track": source = source.replacingOccurrences(of: "COMPONENTS 1", with: "TRACKS Z 3100 DO 5 STEP 200 LAYER metH ;\nCOMPONENTS 1")
        case "multiple-track-layers": source = source.replacingOccurrences(of: "COMPONENTS 1", with: "TRACKS Y 3100 DO 5 STEP 200 LAYER metH metV ;\nCOMPONENTS 1")
        case "missing-end": source = source.replacingOccurrences(of: "END DESIGN", with: "")
        case "trailing-input": source += "\nUNKNOWN ;"
        default: Issue.record("Unknown source DEF counterexample")
        }
        let parsed = PhysicalDesignDEFParser().parseResolved(Data(source.utf8), cellMasters: inputs.cellViews.values.flatMap(\.macros), processFactory: { units in
            try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: units)
        })
        #expect(parsed.result.snapshot == nil && parsed.result.diagnostics.contains { $0.severity == .error }, "\(scenario): \(parsed.result.diagnostics)")
    }

    @Test("source-bound DEF resolves named layers and declared clock use without name inference")
    func sourceDEFLayersAndUse() async throws {
        let (_, request, store) = try await fixture()
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let source = try #require(String(data: sourceDEF(), encoding: .utf8)).replacingOccurrences(of: "COMPONENTS 1", with: "TRACKS Y 3100 DO 5 STEP 200 LAYER metH ;\nPINS 0 ; END PINS\nSPECIALNETS 0 ; END SPECIALNETS\nCOMPONENTS 1").replacingOccurrences(of: "- N (", with: "- clk_data (")
        for clock in [true, false] {
            let text = clock ? source.replacingOccurrences(of: "( U1 Y ) ;", with: "( U1 Y ) + USE CLOCK ;") : source
            let parsed = PhysicalDesignDEFParser().parseResolved(Data(text.utf8), cellMasters: inputs.cellViews.values.flatMap(\.macros), processFactory: { units in
                try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: units)
            })
            let snapshot = try #require(parsed.result.snapshot)
            #expect(snapshot.implementationState?.tracks.first?.layer == 2)
            #expect(snapshot.nets.first?.isClock == clock)
        }
    }

    private func sourceDEF() -> Data {
        Data("""
        VERSION 5.8 ;
        DESIGN fixture_top ;
        UNITS DISTANCE MICRONS 1000 ;
        DIEAREA ( 0 0 ) ( 10000 10000 ) ;
        ROW row unit 0 3000 N DO 100 BY 1 STEP 100 0 ;
        COMPONENTS 1 ;
        - U1 INV_X1 + FIXED ( 2000 3000 ) FN ;
        END COMPONENTS
        NETS 1 ;
        - N ( U1 Y ) ;
        END NETS
        END DESIGN
        """.utf8)
    }

    @Test("DEF retains each oriented source size instead of unrotated master dimensions", arguments: DEFOrientation.allCases)
    func sourceDEFOrientedSize(orientation: DEFOrientation) async throws {
        let (_, request, store) = try await fixture()
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let text = try #require(String(data: sourceDEF(), encoding: .utf8)).replacingOccurrences(of: ") FN", with: ") \(orientation.rawValue)")
        let parsed = PhysicalDesignDEFParser().parseResolved(Data(text.utf8), processFactory: { units in
            try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: units)
        })
        let cell = try #require(parsed.result.snapshot?.cells.first)
        let rotated = [DEFOrientation.e, .w, .fe, .fw].contains(orientation)
        #expect(cell.orientation == orientation)
        #expect(cell.width == (rotated ? 1000 : 2000) && cell.height == (rotated ? 2000 : 1000))
    }

    private func resumed(_ base: PhysicalDesignRequest, from reference: PhysicalDesignReference, runID: String, stage: PhysicalDesignStage,
        processAssets: [String: PhysicalDesignArtifactBinding]? = nil) -> PhysicalDesignRequest {
        PhysicalDesignRequest(runID: runID, inputBindings: base.inputBindings + [reference.layoutArtifact], design: base.design,
            constraints: base.constraints, requestedModeIDs: base.requestedModeIDs, pdk: base.pdk, inputLayout: reference,
            stage: stage, configuration: base.configuration, processAssets: processAssets ?? base.processAssets)
    }

    private func fixture(_ scenario: String = "valid", replacement: String? = nil) async throws -> (PhysicalDesignProcessGeometry, PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore) {
        let store = InMemoryPhysicalDesignArtifactStore()
        var technology = """
        VERSION 5.8 ;
        UNITS DATABASE MICRONS 1000 ; END UNITS
        LAYER metH TYPE ROUTING ; DIRECTION HORIZONTAL ; PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ; END metH
        LAYER cutHV TYPE CUT ; WIDTH 0.05 ; SPACING 0.05 ; END cutHV
        LAYER metV TYPE ROUTING ; DIRECTION VERTICAL ; PITCH 0.4 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ; END metV
        SITE unit CLASS CORE ; SIZE 0.1 BY 1 ; SYMMETRY X Y R90 ; END unit
        VIA hv DEFAULT
          LAYER metH ; RECT -0.1 -0.1 0.1 0.1 ;
          LAYER cutHV ; RECT -0.025 -0.025 0.025 0.025 ;
          LAYER metV ; RECT -0.1 -0.1 0.1 0.1 ;
          RESISTANCE 0.75 ;
        END hv
        END LIBRARY
        """
        var cells = """
        VERSION 5.8 ;
        UNITS DATABASE MICRONS 1000 ; END UNITS
        MACRO INV_X1
          CLASS CORE ; SIZE 2 BY 1 ; ORIGIN 0.1 -0.2 ; SYMMETRY X Y R90 ; SITE unit ;
          PIN Y DIRECTION OUTPUT ; USE SIGNAL ;
            PORT LAYER metH ; RECT 0.1 0.3 0.3 0.5 ; END
          END Y
          PIN A DIRECTION INPUT ; USE SIGNAL ;
            PORT LAYER metH ; POLYGON 0.1 0.2 0.4 0.2 0.4 0.3 0.2 0.3 0.2 0.5 0.1 0.5 ; END
          END A
          OBS LAYER metV ; RECT 1 0.2 1.5 0.5 ; END
        END INV_X1
        END LIBRARY
        """
        switch scenario {
        case "site-y": technology = technology.replacingOccurrences(of: "SYMMETRY X Y R90 ; END unit", with: "SYMMETRY Y ; END unit")
        case "missing-site": cells = cells.replacingOccurrences(of: "SITE unit", with: "SITE missing")
        case "duplicate-site": technology = technology.replacingOccurrences(of: "END LIBRARY", with: "SITE unit CLASS CORE ; SIZE 0.1 BY 1 ; END unit\nEND LIBRARY")
        case "duplicate-master": cells = cells.replacingOccurrences(of: "END LIBRARY", with: "MACRO INV_X1 CLASS CORE ; SIZE 2 BY 1 ; END INV_X1\nEND LIBRARY")
        case "duplicate-pin": cells = cells.replacingOccurrences(of: "PIN A DIRECTION", with: "PIN Y DIRECTION").replacingOccurrences(of: "END A", with: "END Y")
        case "missing-pin-port": cells = cells.replacingOccurrences(of: "PORT LAYER metH ; RECT 0.1 0.3 0.3 0.5 ; END", with: "")
        case "sub-dbu": cells = cells.replacingOccurrences(of: "RECT 0.1 0.3", with: "RECT 0.1005 0.3")
        case "sub-dbu-origin": cells = cells.replacingOccurrences(of: "ORIGIN 0.1 -0.2", with: "ORIGIN 0.1 -0.2005")
        case "shape-range": cells = cells.replacingOccurrences(of: "RECT 0.1 0.3", with: "RECT -3000000 0.3")
        case "zero-rectangle": cells = cells.replacingOccurrences(of: "RECT 0.1 0.3", with: "RECT 0.3 0.3")
        case "diagonal-polygon": cells = cells.replacingOccurrences(of: "POLYGON 0.1 0.2 0.4 0.2 0.4 0.3 0.2 0.3 0.2 0.5 0.1 0.5", with: "POLYGON 0 0 0.4 0 0.1 0.3")
        case "crossing-polygon": cells = cells.replacingOccurrences(of: "POLYGON 0.1 0.2 0.4 0.2 0.4 0.3 0.2 0.3 0.2 0.5 0.1 0.5", with: "POLYGON 0 0 0.4 0 0.4 0.4 0.2 0.4 0.2 -0.1 0 -0.1")
        case "empty-via-layer": technology = technology.replacingOccurrences(of: "RECT -0.025 -0.025 0.025 0.025 ;", with: "")
        case "wrong-lef-cut-type": technology = technology.replacingOccurrences(of: "LAYER cutHV TYPE CUT", with: "LAYER cutHV TYPE ROUTING")
        case "generated-via": technology = technology.replacingOccurrences(of: "VIA hv DEFAULT", with: "VIA hv GENERATE")
        case "no-default-via": technology = technology.replacingOccurrences(of: "VIA hv DEFAULT", with: "VIA hv")
        case "ambiguous-default-via":
            let start = try #require(technology.range(of: "VIA hv DEFAULT"))
            let end = try #require(technology.range(of: "END hv"))
            let duplicate = String(technology[start.lowerBound..<end.upperBound]).replacingOccurrences(of: "hv", with: "hv2")
            technology = technology.replacingOccurrences(of: "END LIBRARY", with: duplicate + "\nEND LIBRARY")
        case "offset-via": technology = technology.replacingOccurrences(of: "RECT -0.1 -0.1 0.1 0.1", with: "RECT 1 1 1.2 1.2")
        case "mask": cells = cells.replacingOccurrences(of: "RECT 0.1 0.3", with: "RECT MASK 1 0.1 0.3")
        case "bad-resistance": technology = technology.replacingOccurrences(of: "RESISTANCE 0.75", with: "RESISTANCE -0.75")
        case "port-via", "missing-port-via": cells = cells.replacingOccurrences(of: "RECT 0.1 0.3 0.3 0.5 ;", with: "VIA 0.2 0.4 \(scenario == "port-via" ? "hv" : "missing") ;")
        default: break
        }
        if let replacement {
            var macro = """
            MACRO INV_X2
              CLASS CORE ; SIZE 3 BY 1 ; ORIGIN 0.2 -0.1 ; SYMMETRY X Y ; SITE unit ;
              PIN Y DIRECTION OUTPUT ; USE SIGNAL ; PORT LAYER metV ; RECT 0.5 0.2 0.7 0.4 ; END END Y
              PIN A DIRECTION INPUT ; USE SIGNAL ; PORT LAYER metH ; RECT 0.1 0.2 0.3 0.4 ; END END A
            END INV_X2
            """
            switch replacement {
            case "ports": macro = macro.replacingOccurrences(of: "PIN A ", with: "PIN B ").replacingOccurrences(of: "END A", with: "END B")
            case "direction": macro = macro.replacingOccurrences(of: "DIRECTION OUTPUT", with: "DIRECTION INPUT")
            case "use": macro = macro.replacingOccurrences(of: "USE SIGNAL", with: "USE CLOCK")
            case "height": macro = macro.replacingOccurrences(of: "SIZE 3 BY 1", with: "SIZE 3 BY 2")
            case "symmetry": macro = macro.replacingOccurrences(of: "SYMMETRY X Y ;", with: "SYMMETRY X ;")
            default: break
            }
            cells = cells.replacingOccurrences(of: "END LIBRARY", with: macro + "\nEND LIBRARY")
        }
        let technologyBinding = try await store.registerInput(Data(technology.utf8), relativePath: "inputs/tech.lef", kind: .technology, format: .lef)
        let cellsBinding = try await store.registerInput(Data(cells.utf8), relativePath: "inputs/cells.lef", kind: .technology, format: .lef)
        var layers: [PDKLayerDefinition] = [
            .init(layerID: "H", name: "metH", number: 2, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "V", name: "metV", number: 3, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "C", name: "cutHV", number: 4, purpose: .via, isRoutingLayer: scenario == "wrong-cut-layer")
        ]
        if scenario == "ambiguous-layer" { layers.append(.init(layerID: "extra", name: "metH", number: 5, purpose: .metal, isRoutingLayer: true)) }
        let layerIDs = layers.map(\.layerID)
        let manifest = PDKManifest(processID: "fixture-130nm", version: "1", assets: [
            .init(assetID: "tech", role: .technology, path: "tech.lef", kind: .technology, format: .lef, sha256: technologyBinding.reference.digest.hexadecimalValue, byteCount: Int64(technology.utf8.count)),
            .init(assetID: "cells", role: .cell, path: "cells.lef", kind: .technology, format: .lef, sha256: cellsBinding.reference.digest.hexadecimalValue, byteCount: Int64(cells.utf8.count))
        ], layers: layers, crossViewMappings: [
            .init(mappingID: "tech", view: .lef, assetID: "tech", layerIDs: layerIDs),
            .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: scenario == "unmapped-master" ? [] : (replacement == nil ? ["INV_X1"] : ["INV_X1", "INV_X2"]), layerIDs: scenario == "unmapped-layer" ? ["V", "C"] : layerIDs)
        ])
        let manifestBinding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        let base = PhysicalDesignFixtureFactory.request(stage: .floorplan)
        let request = PhysicalDesignRequest(runID: "geometry-projection", inputBindings: [manifestBinding] + base.inputBindings.filter { $0.reference == base.design.artifact || $0.reference == base.constraints.reference }, design: base.design, constraints: base.constraints,
            requestedModeIDs: base.requestedModeIDs, pdk: .init(manifest: manifestBinding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: manifestBinding),
                processID: "fixture-130nm", version: "1", digest: manifestBinding.reference.digest.hexadecimalValue),
            processAssets: ["tech": technologyBinding, "cells": cellsBinding])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        return (try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000), request, store)
    }
}
