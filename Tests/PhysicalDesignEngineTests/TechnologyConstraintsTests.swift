import Foundation
import Testing
import CircuiteFoundation
import PDKCore
@testable import PhysicalDesignCore
import PhysicalDesignEngine

@Suite("Native technology constraints")
struct TechnologyConstraintsTests {
    @Test("technology LEF is bound to the PDK and drives retained tracks", arguments: [
        "valid", "missing-pitch", "missing-offset", "wrong-process", "wrong-asset-digest",
        "unmapped", "ambiguous-layer", "off-dbu", "double-pitch", "double-offset",
        "qualified-spacing", "spacing-table", "insufficient-width", "insufficient-spacing",
        "conflicting-tracks", "invalid-encoding", "wrong-version", "wrong-manifest-digest",
        "wrong-asset-size", "empty-lef", "nonfinite", "missing-direction", "malformed-lef", "tiny-core", "aligned-explicit", "shared-layer", "missing-provenance", "invalid-default-width", "unit-precision"
    ])
    func technologyPreparation(scenario: String) async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var text = """
        VERSION 5.8 ;
        UNITS
          DATABASE MICRONS 2000 ;
        END UNITS
        LAYER metH
          TYPE ROUTING ;
          DIRECTION HORIZONTAL ;
          PITCH 0.2 ;
          OFFSET 0.1 ;
          WIDTH 0.1 ;
          SPACING 0.1 ;
        END metH
        LAYER metV
          TYPE ROUTING ;
          DIRECTION VERTICAL ;
          PITCH 0.4 ;
          OFFSET 0.1 ;
          WIDTH 0.1 ;
          SPACING 0.1 ;
        END metV
        END LIBRARY
        """
        switch scenario {
        case "missing-pitch": text = text.replacingOccurrences(of: "PITCH 0.2 ;", with: "")
        case "missing-offset": text = text.replacingOccurrences(of: "OFFSET 0.1 ;", with: "")
        case "off-dbu": text = text.replacingOccurrences(of: "PITCH 0.2 ;", with: "PITCH 0.2005 ;")
        case "double-pitch": text = text.replacingOccurrences(of: "PITCH 0.2 ;", with: "PITCH 0.2 0.4 ;")
        case "double-offset": text = text.replacingOccurrences(of: "OFFSET 0.1 ;", with: "OFFSET 0.1 0.3 ;")
        case "qualified-spacing": text = text.replacingOccurrences(of: "SPACING 0.1 ;", with: "SPACING 0.1 RANGE 0.1 0.2 ;")
        case "spacing-table": text = text.replacingOccurrences(of: "SPACING 0.1 ;", with: "SPACING 0.1 ;\nSPACINGTABLE PARALLELRUNLENGTH 0.1 WIDTH 0.1 0.2 ;")
        case "empty-lef": text = ""
        case "nonfinite": text = text.replacingOccurrences(of: "PITCH 0.2 ;", with: "PITCH nan ;")
        case "missing-direction": text = text.replacingOccurrences(of: "DIRECTION HORIZONTAL ;", with: "")
        case "malformed-lef": text = text.replacingOccurrences(of: "END metH", with: "END wrong")
        case "invalid-default-width": text = text.replacingOccurrences(of: "WIDTH 0.1 ;", with: "WIDTH -0.1 ; MINWIDTH 0.1 ;")
        default: break
        }
        let data = scenario == "invalid-encoding" ? Data([0xff]) : Data(text.utf8)
        let technology = try await store.registerInput(data, relativePath: "inputs/technology.lef", kind: .technology, format: .lef)
        let layers: [PDKLayerDefinition] = [
            .init(layerID: "H", name: "canonicalH", number: 2, purpose: .metal, isRoutingLayer: true, aliases: ["metH"]),
            .init(layerID: "V", name: scenario == "shared-layer" ? "metH" : "metV", number: scenario == "ambiguous-layer" ? 2 : 3, purpose: .metal, isRoutingLayer: true)
        ]
        let manifest = PDKManifest(
            processID: scenario == "wrong-process" ? "another-process" : "fixture-130nm", version: scenario == "wrong-version" ? "2" : "1",
            assets: [.init(assetID: "tech", role: .technology, path: "technology.lef", kind: .technology, format: .lef,
                           sha256: scenario == "wrong-asset-digest" ? String(repeating: "0", count: 64) : technology.reference.digest.hexadecimalValue,
                           byteCount: Int64(data.count) + (scenario == "wrong-asset-size" ? 1 : 0))],
            layers: layers,
            crossViewMappings: [.init(mappingID: "routing", view: .lef, assetID: "tech", layerIDs: scenario == "unmapped" ? ["H"] : ["H", "V"])]
        )
        let manifestBinding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        var configuration = PhysicalDesignFixtureFactory.configuration
        configuration.dieWidth = 180_000
        configuration.preferredRoutingLayers = [2, 3]
        if scenario == "tiny-core" { configuration.dieHeight = 20_050 }
        if scenario == "insufficient-width" { configuration.implementationConstraints = .init(routeWidth: 50) }
        if scenario == "insufficient-spacing" { configuration.implementationConstraints = .init(routeSpacing: 50) }
        var snapshot = PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
        if scenario == "unit-precision" { snapshot.unitsPerMicron = 9_007_199_254_740_993 }
        if scenario == "conflicting-tracks" {
            snapshot.implementationState = .init(tracks: [
                .init(id: "wrong", layer: 2, direction: "vertical", origin: 10_000, spacing: 100, count: 800)
            ])
        }
        if scenario == "aligned-explicit" {
            snapshot.implementationState = .init(tracks: [
                .init(id: "die-h", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 500),
                .init(id: "die-v", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 450)
            ])
        }
        var request = PhysicalDesignFixtureFactory.request(stage: .floorplan, snapshot: snapshot, configuration: configuration)
        request.pdk = PDKReference(manifest: manifestBinding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: manifestBinding),
                                   processID: "fixture-130nm", version: "1", digest: scenario == "wrong-manifest-digest" ? String(repeating: "0", count: 64) : manifestBinding.reference.digest.hexadecimalValue)
        request.inputs.append(contentsOf: [manifestBinding.reference, technology.reference])
        request.inputBindings.append(contentsOf: [manifestBinding, technology])
        if scenario == "missing-provenance" { request.inputs.removeAll { $0 == technology.reference } }
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        if scenario == "valid" || scenario == "aligned-explicit" {
            #expect(result.status == .completed, "\(result.diagnostics)")
            let binding = try #require(result.artifactBindings.first { $0.path.hasSuffix("revision.json") })
            let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(binding))
            let tracks = try #require(output.implementationState?.tracks)
            let horizontal = try #require(tracks.first { $0.layer == 2 })
            let vertical = try #require(tracks.first { $0.layer == 3 })
            #expect(horizontal.direction == "horizontal")
            #expect(horizontal.spacing == 200)
            #expect(horizontal.origin == (scenario == "valid" ? 10_100 : 100))
            #expect(horizontal.count == (scenario == "valid" ? 400 : 500))
            #expect(vertical.direction == "vertical")
            #expect(vertical.spacing == 400)
            #expect(vertical.origin == (scenario == "valid" ? 10_100 : 100))
            #expect(vertical.count == (scenario == "valid" ? 400 : 450))
            if scenario == "aligned-explicit" { #expect(tracks == snapshot.implementationState?.tracks) }
            #expect(result.provenance.inputs.contains(technology.reference))
            var omitted = request
            omitted.runID = "test-omitted-technology-\(scenario)"
            omitted.initialSnapshot = output
            omitted.inputs.removeAll { $0 == technology.reference }
            omitted.inputBindings.removeAll { $0 == technology }
            let replay = try await PhysicalDesignEngine(artifactStore: store).execute(omitted)
            #expect(replay.status == .blocked)
            #expect(replay.artifacts.isEmpty)
            #expect(replay.diagnostics.contains { $0.code.rawValue == "physical_technology_invalid" })
        } else {
            #expect(result.status == .blocked)
            #expect(result.artifacts.isEmpty)
            #expect(result.diagnostics.contains { $0.code.rawValue.hasPrefix("physical_technology_") })
        }
        #expect(result.payload.claims.production == .blocked)
    }
}
