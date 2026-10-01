import Foundation
import Testing
import CircuiteFoundation
import DEF
import LEF
import LayoutIR
import MaskGeometry
import PDKCore
@testable import PhysicalDesignCore

@Suite("Exact native process geometry projection")
struct ProcessGeometryTests {
    @Test("source-bound geometry preserves origin and all standard orientations")
    func projectedGeometry() async throws {
        let (geometry, request) = try await fixture()
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
        let (geometry, _) = try await fixture("port-via")
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

    private func fixture(_ scenario: String = "valid") async throws -> (PhysicalDesignProcessGeometry, PhysicalDesignRequest) {
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
        let request = PhysicalDesignRequest(runID: "geometry-projection", inputBindings: [manifestBinding], design: base.design, constraints: base.constraints,
            requestedModeIDs: base.requestedModeIDs, pdk: .init(manifest: manifestBinding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: manifestBinding),
                processID: "fixture-130nm", version: "1", digest: manifestBinding.reference.digest.hexadecimalValue),
            processAssets: ["tech": technologyBinding, "cells": cellsBinding])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        return (try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000), request)
    }
}
