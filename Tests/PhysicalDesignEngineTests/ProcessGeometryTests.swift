import Foundation
import Testing
import CircuiteFoundation
import DEF
import LEF
import LayoutIR
import MaskGeometry
import PDKCore
import PhysicalDesignEngine
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
        var resize = resumed(request, from: placedReference, runID: "fabricated-resize", stage: .timingECO)
        resize.configuration.ecoTargetCellID = "U1"
        let rejectedResize = try await engine.execute(resize)
        #expect(rejectedResize.status == .blocked && rejectedResize.artifactBindings.isEmpty)
        #expect(rejectedResize.diagnostics.contains { $0.code.rawValue == "process_geometry_invalid" })
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

    private func resumed(_ base: PhysicalDesignRequest, from reference: PhysicalDesignReference, runID: String, stage: PhysicalDesignStage,
        processAssets: [String: PhysicalDesignArtifactBinding]? = nil) -> PhysicalDesignRequest {
        PhysicalDesignRequest(runID: runID, inputBindings: base.inputBindings + [reference.layoutArtifact], design: base.design,
            constraints: base.constraints, requestedModeIDs: base.requestedModeIDs, pdk: base.pdk, inputLayout: reference,
            stage: stage, configuration: base.configuration, processAssets: processAssets ?? base.processAssets)
    }

    private func fixture(_ scenario: String = "valid") async throws -> (PhysicalDesignProcessGeometry, PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore) {
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
        case "mask": cells = cells.replacingOccurrences(of: "RECT 0.1 0.3", with: "RECT MASK 1 0.1 0.3")
        case "bad-resistance": technology = technology.replacingOccurrences(of: "RESISTANCE 0.75", with: "RESISTANCE -0.75")
        case "port-via", "missing-port-via": cells = cells.replacingOccurrences(of: "RECT 0.1 0.3 0.3 0.5 ;", with: "VIA 0.2 0.4 \(scenario == "port-via" ? "hv" : "missing") ;")
        default: break
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
            .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: scenario == "unmapped-master" ? [] : ["INV_X1"], layerIDs: scenario == "unmapped-layer" ? ["V", "C"] : layerIDs)
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
