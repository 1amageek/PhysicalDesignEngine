import CircuiteFoundation
import DEF
import Foundation
import LayoutIR
import MaskGeometry
import PDKCore
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Actual fixed-contact terminal access", .timeLimit(.minutes(1)))
struct TerminalViaAccessTests {
    @Test func actualSourceContactPersistsAndReconstructsStandardMetal() async throws {
        let fixture = try await fixture()
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(fixture.request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let codec = PhysicalDesignJSONCodec()
        let output = try codec.decode(PhysicalDesignSnapshot.self,
            from: await fixture.store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        try verify(output, geometry: fixture.geometry)
        let standard = try DEFLibraryReader.read(await fixture.store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })))
        let net = try #require(standard.nets.first { $0.name == "N" })
        let contacts = net.routing.filter { $0.viaName != nil }
        #expect(contacts.count == output.vias.count)
        for via in output.vias {
            #expect(contacts.contains { $0.viaName == via.master && $0.points.count == 1 && Int64($0.points[0].x) == via.x && Int64($0.points[0].y) == via.y })
        }
        var canonical: [Int16: Region] = [:], decoded: [Int16: Region] = [:]
        func merge(_ region: Region, into result: inout [Int16: Region]) throws {
            result[region.layer] = try (result[region.layer] ?? Region(layer: region.layer)).union(region)
        }
        for segment in output.routes.flatMap(\.segments) {
            try merge(PhysicalDesignSourceRouter.conductor(segment, width: #require(segment.widthDBU)), into: &canonical)
        }
        for via in output.vias {
            for shape in try fixture.geometry.viaShapes(master: #require(via.master), x: via.x, y: via.y) { try merge(Region(layer: shape.layer, polygons: [shape]), into: &canonical) }
        }
        for route in net.routing {
            if let name = route.viaName {
                let point = try #require(route.points.first)
                for shape in try fixture.geometry.viaShapes(master: name, x: Int64(point.x), y: Int64(point.y)) { try merge(Region(layer: shape.layer, polygons: [shape]), into: &decoded) }
            } else {
                #expect(route.layerName == "met1" && route.points.count == 2 && route.pointExtensions.count == 2)
                let first = route.points[0], last = route.points[1]
                let segment = PhysicalDesignSnapshot.RouteSegment(id: "decoded", layer: 2,
                    x1: Int64(first.x), y1: Int64(first.y), x2: Int64(last.x), y2: Int64(last.y), widthDBU: 140,
                    endpointExtensions: .init(beginDBU: Int64(try #require(route.pointExtensions[0])), endDBU: Int64(try #require(route.pointExtensions[1]))))
                try merge(PhysicalDesignSourceRouter.conductor(segment, width: 140), into: &decoded)
            }
        }
        #expect(Set(canonical.keys) == Set(decoded.keys))
        for (layer, region) in canonical { #expect(try region.symmetricDifference(#require(decoded[layer])).isEmpty) }
        #expect(try codec.decode(PhysicalDesignSnapshot.self, from: codec.encode(output)) == output)
    }

    @Test(arguments: ["missing", "spacing"])
    func unavailableOrBlockedContactCannotPublish(scenario: String) async throws {
        let fixture = try await fixture()
        var request = fixture.request
        if scenario == "missing" {
            request.configuration.preferredRoutingLayers = [1]
            request.initialSnapshot?.pins[1].accessLayer = 1
            request.initialSnapshot?.pins[1].x = 2070
            request.initialSnapshot?.pins[1].topPort = .init(rectangle: .init(x: -100, y: -100, width: 200, height: 200), layer: 1,
                placementX: 2070, placementY: 7310, orientation: .n, placementStatus: .fixed, use: .signal)
        } else {
            request.stage = .timingECO
            request.configuration.ecoAction = .rerouteNet; request.configuration.ecoTargetNetID = "N"
            request.initialSnapshot?.nets.append(.init(id: "M", pinIDs: []))
            request.initialSnapshot?.routes = [.init(id: "blocking-M", netID: "M", segments:
                [5950, 6290, 6630, 6970, 7310, 7650].map { y in
                    .init(id: "M-\(y)", layer: 2, x1: 660, y1: Int64(y), x2: 1200, y2: Int64(y),
                        widthDBU: 140, endpointExtensions: .init(beginDBU: 70, endDBU: 70))
                }, defStatus: .routed)]
        }
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil)
        #expect(result.diagnostics.contains { $0.summary.contains("access") || $0.summary.contains("spacing") }, "\(result.diagnostics)")
    }

    @Test func fixedAccessUsesOneCumulativeQuotaAndChecksCancellation() async throws {
        let fixture = try await fixture()
        let input = try #require(fixture.request.initialSnapshot)
        let router = PhysicalDesignSourceRouter()
        let measured = try router.route(input, configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        try verify(measured.snapshot, geometry: fixture.geometry)
        var configuration = fixture.request.configuration
        configuration.maximumRoutingCandidateChecks = measured.checks
        let exact = try router.route(input, configuration: configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
        #expect(exact.checks == measured.checks && exact.snapshot.routes == measured.snapshot.routes && exact.snapshot.vias == measured.snapshot.vias)
        configuration.maximumRoutingCandidateChecks = measured.checks - 1
        do {
            _ = try router.route(input, configuration: configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
            Issue.record("Terminal contact reset or ignored the caller budget")
        } catch let error as PhysicalDesignSourceRouter.Failure { #expect(error.code == "routing_candidate_budget_exhausted") }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try router.route(input, configuration: fixture.request.configuration, mode: "global", onlyNetID: nil, geometry: fixture.geometry)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel(); #expect(await task.value)
    }

    private func verify(_ output: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws {
        try geometry.validate(output)
        let source = try #require(output.pins.first { $0.id == "U/Y" })
        #expect(source.accessLayer == 1 && source.cellID == "U" && source.netID == "N")
        #expect(output.vias.count == 1)
        let contact = try #require(output.vias.first, "Actual selected contacts: \(output.vias)")
        // Full 170-DBU terminal metal inside the source's 720...1050 surface gives this finite grid domain.
        #expect((805...965).contains(contact.x) && contact.x.isMultiple(of: 5) && contact.y == 7310)
        #expect(source.x == contact.x && source.y == contact.y)
        #expect(contact.master == "L1M1_PR" && contact.lowerLayer == 1 && contact.upperLayer == 2)
        let port = Region(layer: 1, polygons: try geometry.pinShapes(master: "sky130_fd_sc_hd__inv_1", pin: "Y", orientation: .n, x: 0, y: 5440).filter { $0.layer == 1 })
        let metal = Region(layer: 1, polygons: try geometry.viaShapes(master: "L1M1_PR", x: contact.x, y: contact.y).filter { $0.layer == 1 })
        #expect(try metal.subtracting(port).isEmpty)
        #expect(output.routes.flatMap(\.segments).allSatisfy { $0.layer == 2 && $0.widthDBU == 140 && $0.y1 == 7310 && $0.y2 == 7310 })
        #expect(!output.routes.flatMap(\.segments).isEmpty)
    }

    private func fixture() async throws -> (geometry: PhysicalDesignProcessGeometry, request: PhysicalDesignRequest, store: InMemoryPhysicalDesignArtifactStore) {
        let store = InMemoryPhysicalDesignArtifactStore()
        let sourceRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "PhysicalLogicHandoffTests/Fixtures/NativeCTS/Sky130")
        let technology = try await store.registerInput(Data(contentsOf: sourceRoot.appending(path: "technology.lef")), relativePath: "inputs/tech.lef", kind: .technology, format: .lef)
        let cells = try await store.registerInput(Data(contentsOf: sourceRoot.appending(path: "cells.lef")), relativePath: "inputs/cells.lef", kind: .technology, format: .lef)
        let layers: [PDKLayerDefinition] = [.init(layerID: "li1", name: "li1", number: 1, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "met1", name: "met1", number: 2, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "mcon", name: "mcon", number: 3, purpose: .via),
            .init(layerID: "nwell", name: "nwell", number: 4, purpose: .well), .init(layerID: "pwell", name: "pwell", number: 5, purpose: .well)]
        let manifest = PDKManifest(processID: "actual-terminal-access", version: "1", assets: [("tech", PDKAssetRole.technology, technology), ("cells", .cell, cells)].map { id, role, binding in
            .init(assetID: id, role: role, path: binding.path, kind: binding.descriptor.kind, format: binding.descriptor.format,
                sha256: binding.reference.digest.hexadecimalValue, byteCount: Int64(binding.reference.byteCount))
        }, layers: layers, crossViewMappings: [.init(mappingID: "tech", view: .lef, assetID: "tech", layerIDs: layers.map(\.layerID)),
            .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: ["sky130_fd_sc_hd__buf_1", "sky130_fd_sc_hd__inv_1", "sky130_fd_sc_hd__dfxtp_1"], layerIDs: layers.map(\.layerID))])
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        let design = try await store.registerInput(Data("module top(output N); sky130_fd_sc_hd__inv_1 U(.Y(N)); endmodule\n".utf8), relativePath: "inputs/design.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Actual source geometry access; no timing claim.\n".utf8), relativePath: "inputs/design.sdc", kind: .constraint, format: .sdc)
        var snapshot = PhysicalDesignSnapshot(topCell: "top", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 18400, height: 8160), core: .init(x: 0, y: 0, width: 18400, height: 8160),
            rows: [.init(id: "row", originX: 0, originY: 5440, siteWidth: 460, height: 2720, siteCount: 40, siteName: "unithd")],
            cells: [.init(id: "U", master: "sky130_fd_sc_hd__inv_1", x: 0, y: 5440, width: 1380, height: 2720, placed: true, locked: true)],
            pins: [.init(id: "U/Y", cellID: "U", name: "Y", netID: "N", direction: "output", accessLayer: 1),
                .init(id: "OUT", cellID: nil, name: "N", x: 2000, y: 7310, netID: "N", direction: "output", accessLayer: 2,
                    topPort: .init(rectangle: .init(x: -100, y: -100, width: 200, height: 200), layer: 2,
                        placementX: 2000, placementY: 7310, orientation: .n, placementStatus: .fixed, use: .signal))],
            nets: [.init(id: "N", pinIDs: ["U/Y", "OUT"])],
            implementationState: .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 170, spacing: 340, count: 24),
                .init(id: "V", layer: 1, direction: "vertical", origin: 230, spacing: 460, count: 40)]))
        var request = PhysicalDesignRequest(runID: "terminal-contact", inputBindings: [pdk, design, constraints],
            design: .init(artifact: design.reference, topDesignName: "top", designDigest: design.reference.digest.hexadecimalValue), constraints: constraints,
            requestedModeIDs: ["functional"], pdk: try .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk), processID: manifest.processID, version: manifest.version),
            stage: .globalRouting, configuration: .init(rowHeight: 2720, siteWidth: 460, preferredRoutingLayers: [1, 2], maximumRoutingLayer: 2,
                implementationConstraints: .init(routeWidth: 170, routeSpacing: 140, sourceRoutingWidthPolicy: .sourceDefault)),
            initialSnapshot: snapshot, processAssets: ["tech": technology, "cells": cells])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        snapshot.pins[0] = try geometry.referencePin(snapshot.pins[0], for: snapshot.cells[0])
        request.initialSnapshot = try geometry.bind(snapshot)
        return (geometry, request, store)
    }
}
