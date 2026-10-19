import CircuiteFoundation
import CircuiteFoundationCrypto
import DRCNative
import Foundation
import MaskGeometry
import PDKCore
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

/// Selected unqualified Sky130 source evidence, not foundry, timing, RC or whole-process qualification.
@Suite("Actual original Sky130 source antenna PAR", .serialized, .timeLimit(.minutes(2)))
struct ActualSky130SourceAntennaTests {
    private static let master = "sky130_fd_sc_hd__buf_1"
    private static let originRoot = "/Users/1amageek/.volare/volare/sky130/versions/c6d73a35f524070e85faff4a6a9eef49553ebc2b/sky130A/libs.ref/sky130_fd_sc_hd/"
    private struct RangeEvidence: Codable {
        let originStart: Int
        let originEnd: Int
        let selectedStart: Int
        let sha256: String
    }
    private struct SourceEvidence: Codable {
        let origin: String
        let originSHA256: String
        let originByteCount: Int
        let selectedSHA256: String
        let selectedByteCount: Int
        let ranges: [RangeEvidence]
        let excludedFacts: [String]
    }

    @Test("original source laws and terminals survive API and CLI candidate persistence")
    func actualSourceAPIAndCLI() async throws {
        let (request, memory, geometry) = try await fixture()
        let retained = ProcessInfo.processInfo.environment["LSI_PHYSICAL_S3_EVIDENCE_ROOT"]
        let root = retained.map { URL(fileURLWithPath: $0).appending(path: "actual-sky130-source-antenna") }
            ?? FileManager.default.temporaryDirectory.appending(path: "actual-sky130-source-antenna-\(UUID().uuidString)")
        try #require(!FileManager.default.fileExists(atPath: root.path))
        let apiRoot = root.appending(path: "api"), cliRoot = root.appending(path: "cli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if retained == nil { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        }
        let codec = PhysicalDesignJSONCodec()
        for directory in [apiRoot, cliRoot] {
            for binding in request.inputBindings {
                let path = directory.appending(path: binding.path)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await memory.read(binding).write(to: path)
            }
            try codec.encode(request).write(to: directory.appending(path: "request.json"))
        }
        let api = try await PhysicalDesignEngine(artifactStore: FileSystemPhysicalDesignArtifactStore(projectRoot: apiRoot)).execute(request)
        try codec.encode(api).write(to: apiRoot.appending(path: "api-result.json"))
        #expect(api.status == .completed, "\(api.diagnostics)")
        guard api.status == .completed else { #expect(api.artifactBindings.isEmpty); return }
        let apiReloaded = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: apiRoot.appending(path: "api-result.json")))
        let apiEvidence = try await verify(apiReloaded, request: request,
            store: FileSystemPhysicalDesignArtifactStore(projectRoot: apiRoot), geometry: geometry)
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", cliRoot.appending(path: "request.json").path, "--project-root", cliRoot.path]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let cliResultURL = cliRoot.appending(path: "cli-result.json")
        try bytes.write(to: cliResultURL)
        let command: [String: Any] = ["executable": try #require(process.executableURL).path,
            "arguments": try #require(process.arguments), "exit": process.terminationStatus]
        try JSONSerialization.data(withJSONObject: command, options: [.prettyPrinted, .sortedKeys])
            .write(to: cliRoot.appending(path: "cli-command.json"))
        let cli = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: cliResultURL))
        #expect(process.terminationStatus == 0 && cli.status == .completed, "\(cli.diagnostics)")
        guard cli.status == .completed else { #expect(cli.artifactBindings.isEmpty); return }
        let cliEvidence = try await verify(cli, request: request,
            store: FileSystemPhysicalDesignArtifactStore(projectRoot: cliRoot), geometry: geometry)
        #expect(cliEvidence.candidateSnapshotDigest == apiEvidence.candidateSnapshotDigest)
        #expect(cliEvidence.checks == apiEvidence.checks)
    }

    private func fixture() async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore, PhysicalDesignProcessGeometry) {
        let store = InMemoryPhysicalDesignArtifactStore(), codec = PhysicalDesignJSONCodec()
        let technology = try Self.checkedSource(Self.technologyText, evidence: Self.technologyEvidence)
        let cells = try Self.checkedSource(Self.cellText, evidence: Self.cellEvidence)
        let tech = try await store.registerInput(technology, relativePath: "inputs/selected-original-tech.lef", kind: .technology, format: .lef)
        let cellSource = try await store.registerInput(cells, relativePath: "inputs/selected-original-buf.lef", kind: .technology, format: .lef)
        let provenance = try await store.registerInput(try codec.encode([Self.technologyEvidence, Self.cellEvidence]),
            relativePath: "inputs/source-ranges.json", kind: .technology, format: .json)
        let layers: [PDKLayerDefinition] = [
            .init(layerID: "li1", name: "li1", number: 1, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "mcon", name: "mcon", number: 2, purpose: .via),
            .init(layerID: "met1", name: "met1", number: 3, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "nwell", name: "nwell", number: 4, purpose: .well),
            .init(layerID: "pwell", name: "pwell", number: 5, purpose: .well)
        ]
        let manifest = PDKManifest(processID: "sky130-selected-original-antenna-unqualified", version: "c6d73a35-selected-v1",
            assets: [("tech", PDKAssetRole.technology, tech), ("cells", .cell, cellSource)].map { id, role, source in
                .init(assetID: id, role: role, path: source.path, kind: .technology, format: .lef,
                    sha256: source.reference.digest.hexadecimalValue, byteCount: Int64(source.reference.byteCount))
            }, layers: layers, crossViewMappings: [
                .init(mappingID: "tech", view: .lef, assetID: "tech", layerIDs: layers.map(\.layerID)),
                .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: [Self.master], layerIDs: layers.map(\.layerID))
            ])
        let validation = manifest.validate()
        // This selected geometry/antenna view does not invent device or corner qualification.
        try #require(!validation.isValid)
        try #require(validation.findings.count == 2 && validation.findings.allSatisfy { $0.severity == .blocker })
        try #require(Set(validation.findings.map(\.code)) == Set([
            "pdk.manifest.devices-missing", "pdk.manifest.corners-missing"
        ]), "\(validation.findings)")
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        var input = PhysicalDesignSnapshot(topCell: "selected_source_antenna", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 7360, height: 8160), core: .init(x: 0, y: 0, width: 7360, height: 8160),
            rows: [0, 2720, 5440].map { .init(id: "row-\($0)", originX: 0, originY: Int64($0), siteWidth: 460,
                height: 2720, siteCount: 16, siteName: "unithd") },
            implementationState: .init(tracks: [
                .init(id: "LI", layer: 1, direction: "vertical", origin: 230, spacing: 460, count: 16),
                .init(id: "M1", layer: 3, direction: "horizontal", origin: 170, spacing: 340, count: 24)]))
        input.cells = [920, 3220].enumerated().map { index, x in
            .init(id: index == 0 ? "S" : "G", master: Self.master, x: Int64(x), y: 2720,
                width: 1380, height: 2720, placed: true, locked: true)
        }
        input.pins = [.init(id: "S/X", cellID: "S", name: "X", netID: "N", direction: "output"),
            .init(id: "G/A", cellID: "G", name: "A", netID: "N", direction: "input")]
        input.nets = [.init(id: "N", pinIDs: ["S/X", "G/A"])]
        let design = try await store.registerInput(try codec.encode(input), relativePath: "inputs/design.json", kind: .netlist, format: .json)
        let sdc = try await store.registerInput(Data("# Selected source geometry and antenna only; no timing claim.\n".utf8),
            relativePath: "inputs/design.sdc", kind: .constraint, format: .sdc)
        let profile = PhysicalDesignRepairMeasurementProfile(processManifest: pdk.reference,
            processAssets: ["tech": tech.reference, "cells": cellSource.reference], processLayerOrder: ["li1", "mcon", "met1"],
            rules: [], antennaNetIDs: ["N"], antennaLimitPolicy: .sourceProcessLaws)
        let measurement = try await store.registerInput(try codec.encode(profile), relativePath: "inputs/measurement.json", kind: .technology, format: .json)
        var request = PhysicalDesignRequest(runID: "actual-sky130-source-antenna", inputBindings: [pdk, tech, cellSource, provenance, design, sdc, measurement],
            design: .init(artifact: design.reference, topDesignName: input.topCell, designDigest: design.reference.digest.hexadecimalValue), constraints: sdc,
            requestedModeIDs: ["functional"], pdk: try .init(manifest: pdk.reference,
                manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk), processID: manifest.processID, version: manifest.version),
            stage: .detailedRouting, configuration: .init(dieWidth: 7360, dieHeight: 8160, coreMargin: 0,
                rowHeight: 2720, siteWidth: 460, placementSpacing: 0, preferredRoutingLayers: [1, 3], maximumRoutingLayer: 3,
                implementationConstraints: .init(routeWidth: 170, routeSpacing: 140, sourceRoutingWidthPolicy: .sourceDefault)),
            initialSnapshot: input, processAssets: ["tech": tech, "cells": cellSource],
            repairMeasurementProfile: .init(artifact: measurement, limits: .init(maximumInputBytes: 8_000_000,
                maximumProjectionRecords: 10_000, maximumGeometryProbes: 2_000_000, maximumBackendWork: 2_000_000, timeoutSeconds: 30)))
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        #expect(geometry.sourceLayers[1]?.direction?.rawValue.lowercased() == "vertical")
        #expect(geometry.sourceLayers[1]?.thickness == 0.1 && geometry.sourceLayers[3]?.thickness == 0.35)
        #expect(geometry.vias["L1M1_PR"]?.cutLayer == 2)
        #expect(try geometry.requireMaster(Self.master).obstructions.count == 11)
        for index in input.pins.indices {
            let cell = try #require(input.cells.first { $0.id == input.pins[index].cellID })
            input.pins[index] = try geometry.referencePin(input.pins[index], for: cell)
        }
        request.initialSnapshot = try PhysicalDesignTechnologyConstraints.prepare(geometry.bind(input), request: request, processInputs: inputs, processGeometry: geometry)
        try geometry.validate(try #require(request.initialSnapshot))
        return (request, store, geometry)
    }

    private func verify(_ result: PhysicalDesignResult, request: PhysicalDesignRequest,
                        store: any PhysicalDesignArtifactStore, geometry: PhysicalDesignProcessGeometry) async throws -> PhysicalDesignSourceAntennaMeasurementEvidence {
        let codec = PhysicalDesignJSONCodec()
        #expect(result.payload.claims.production == .blocked)
        let manifestBinding = try #require(result.artifactBindings.first { $0.logicalID.hasSuffix("manifest") })
        let manifest = try codec.decode(PhysicalDesignRunManifest.self, from: await store.read(manifestBinding))
        #expect(manifest.validationDiagnostics().isEmpty)
        let evidence = try #require(manifest.sourceAntennaMeasurementEvidence)
        #expect(evidence.coverage == .clean && evidence.targetNetIDs == ["N"])
        #expect(evidence.processManifest == request.pdk.manifest && evidence.processAssets == request.processAssets.mapValues(\.reference))
        let savedBinding = try #require(result.payload.physicalDesign?.layoutArtifact)
        let bytes = try await store.read(savedBinding)
        let saved = try codec.decode(PhysicalDesignSnapshot.self, from: bytes)
        #expect(try codec.encode(saved) == bytes)
        #expect(try SHA256ContentDigester().digest(data: bytes, using: .sha256) == evidence.candidateSnapshotDigest)
        #expect(evidence.candidateSnapshotDigest == savedBinding.reference.digest)
        try geometry.validate(saved)
        let initial = try #require(request.initialSnapshot)
        #expect(saved.cells == initial.cells)
        #expect(saved.pins.count == initial.pins.count && Set(saved.pins.map(\.id)) == Set(initial.pins.map(\.id)))
        #expect(saved.implementationState?.tracks == initial.implementationState?.tracks)
        for pin in saved.pins {
            let original = try #require(initial.pins.first { $0.id == pin.id })
            var identity = pin; identity.x = original.x; identity.y = original.y
            #expect(identity == original)
            let cell = try #require(saved.cells.first { $0.id == pin.cellID })
            let layer = try #require(pin.accessLayer), nativeLayer = try #require(Int16(exactly: layer))
            let shapes = try geometry.pinShapes(master: cell.master, pin: pin.name, orientation: cell.orientation, x: cell.x, y: cell.y)
            let port = Region(layer: nativeLayer, polygons: shapes.filter { $0.layer == nativeLayer })
            let width = try geometry.routingWidthAndSpacing(layer: layer, units: saved.unitsPerMicron,
                width: nil, areaHandledSeparately: true).width
            let cap = try PhysicalDesignSourceRouter.rectangle(.init(x: pin.x - width / 2, y: pin.y - width / 2,
                width: width, height: width), layer: layer)
            #expect(try cap.subtracting(port).isEmpty)
            let direction = try #require(geometry.sourceLayers[nativeLayer]?.direction?.rawValue.lowercased())
            #expect((saved.implementationState?.tracks ?? []).contains { track in
                guard track.layer == layer, track.direction.lowercased() == direction, track.spacing > 0 else { return false }
                let coordinate = direction == "vertical" ? pin.x : pin.y
                let offset = coordinate - track.origin
                return offset >= 0 && offset.isMultiple(of: track.spacing) && offset / track.spacing < track.count
            })
            let contact = try #require(saved.vias.first {
                $0.netID == pin.netID && $0.x == pin.x && $0.y == pin.y && ($0.lowerLayer == layer || $0.upperLayer == layer)
            })
            let viaShapes = try geometry.viaShapes(master: #require(contact.master), x: contact.x, y: contact.y)
            let terminalMetal = Region(layer: nativeLayer, polygons: viaShapes.filter { $0.layer == nativeLayer })
            #expect(!terminalMetal.isEmpty)
            #expect(try terminalMetal.subtracting(port).isEmpty)
            let neighboringLayer = contact.lowerLayer == layer ? contact.upperLayer : contact.lowerLayer
            let neighboringNative = try #require(Int16(exactly: neighboringLayer))
            let neighboringMetal = Region(layer: neighboringNative, polygons: viaShapes.filter { $0.layer == neighboringNative })
            var joined = false
            for route in saved.routes where route.netID == pin.netID {
                for segment in route.segments where segment.layer == neighboringLayer {
                    let wire = try PhysicalDesignSourceRouter.conductor(segment, width: #require(segment.widthDBU))
                    if try !neighboringMetal.intersection(wire).isEmpty { joined = true }
                }
            }
            #expect(joined)
        }
        #expect(saved.pins.allSatisfy { $0.cellID != nil } && saved.nets.count == 1)
        #expect(saved.routes.flatMap(\.segments).contains { $0.layer == 3 })
        #expect(!saved.vias.isEmpty && saved.vias.allSatisfy { $0.master == "L1M1_PR" && $0.lowerLayer == 1 && $0.upperLayer == 3 })
        for segment in saved.routes.flatMap(\.segments) where segment.layer == 1 { #expect(segment.x1 == segment.x2 && segment.widthDBU == 170) }
        let check = try #require(evidence.checks.first)
        #expect(evidence.checks.count == 1 && check.phase == "candidate" && check.snapshotDigest == evidence.candidateSnapshotDigest)
        #expect(["pwell", "nwell"].allSatisfy { name in
            check.nonConductorRecords.contains { $0.sourceLayerName == name && $0.sourceKind == .masterslice }
        })
        #expect(check.nonConductorRecords.allSatisfy { record in
            !check.input.rectangles.contains { $0.id == record.recordID }
        })
        let gate = try #require(check.terminalDeclarations.first { $0.pinID == "G/A" })
        let driver = try #require(check.terminalDeclarations.first { $0.pinID == "S/X" })
        #expect(gate.rawGateAreaSquareMicrons == 0.1965 && gate.rawDiffusionAreaSquareMicrons == nil)
        #expect(gate.reportedDiffusionAreaSquareMicrons == 0 && gate.diffusionOrigin == "omitted_unqualified_zero")
        #expect(driver.rawGateAreaSquareMicrons == nil && driver.rawDiffusionAreaSquareMicrons == 0.3406)
        #expect(driver.reportedDiffusionAreaSquareMicrons == 0.3406 && driver.diffusionOrigin == "explicit")
        #expect(check.input.layers.map(\.id) == ["li1", "mcon", "met1"] && check.input.rules.count == 3)
        let sourceCell = try #require(request.processAssets["cells"])
        #expect(check.terminalDeclarations.allSatisfy { $0.source == sourceCell.reference })
        for terminal in check.input.terminals {
            let sourcePin = terminal.id == "S/X" ? "X" : "A"
            let shapes = try geometry.requireMaster(Self.master).pins[sourcePin]?.shapes
            #expect(terminal.portRecordIDs.count == shapes?.count)
            #expect(terminal.portRecordIDs.allSatisfy { id in check.input.rectangles.contains { $0.id == id && $0.netID == "N" } })
        }
        let li = try #require(check.input.rules.first { $0.layerID == "li1" })
        let cut = try #require(check.input.rules.first { $0.layerID == "mcon" })
        let metal = try #require(check.input.rules.first { $0.layerID == "met1" })
        #expect(li.basis == .sidewall && li.thicknessMicrons == 0.1 && metal.basis == .sidewall && metal.thicknessMicrons == 0.35)
        #expect(cut.basis == .cutArea)
        for rule in check.input.rules {
            #expect(rule.oxide == "OXIDE1")
            if case .pwl(let points) = rule.limit {
                #expect(points.map(\.diffusionAreaSquareMicrons) == [0, 0.0125, 0.0225, 22.5])
            } else { Issue.record("An original PWL law was replaced.") }
        }
        if case .pwl(let points) = li.limit { #expect(points.map(\.ratio) == [75, 75, 85.125, 10200]); #expect(points.map(\.diffusionAreaSquareMicrons) == [0, 0.0125, 0.0225, 22.5]) }
        else { Issue.record("Original li1 PWL was replaced.") }
        if case .pwl(let points) = cut.limit { #expect(points.map(\.ratio) == [3, 3, 3.405, 408]) }
        else { Issue.record("Original mcon PWL was replaced.") }
        if case .pwl(let points) = metal.limit { #expect(points.map(\.ratio) == [400, 400, 2609, 11600]) }
        else { Issue.record("Original met1 PWL was replaced.") }
        #expect(check.result.nonGateComponents.contains { $0.stageLayerID == "li1" && $0.terminalIDs == ["S/X"] && $0.reason == .noGateAtPrefix })
        let first = try #require(check.result.measurements.first { $0.stageLayerID == "li1" })
        #expect(first.terminalIDs == ["G/A"] && first.gateAreaSquareMicrons == 0.1965 && first.diffusionAreaSquareMicrons == 0 && first.limit == 75)
        let final = try #require(check.result.measurements.first { $0.stageLayerID == "met1" })
        #expect(final.terminalIDs == ["G/A", "S/X"] && final.gateAreaSquareMicrons == 0.1965 && final.diffusionAreaSquareMicrons == 0.3406)
        let expected = 2609 + (0.3406 - 0.0225) / (22.5 - 0.0225) * (11600 - 2609)
        #expect(abs(final.limit - expected) < 1e-9)
        #expect(check.result.measurements.allSatisfy { $0.passed })
        var budget = try NativeSourceAntennaBudget(limits: .init(maximumInputRecords: 10_000, maximumResults: 10_000,
            maximumWork: 2_000_000, maximumStorageEntries: 10_000))
        let replay = try NativeSourceAntennaEvaluator().evaluate(check.input, budget: &budget, isCancelled: { false })
        #expect(replay == check.result)
        let provenance = try #require(request.inputBindings.first { $0.path == "inputs/source-ranges.json" })
        let mapping = try codec.decode([SourceEvidence].self, from: await store.read(provenance))
        #expect(mapping.map(\.selectedSHA256) == [Self.technologyEvidence.selectedSHA256, Self.cellEvidence.selectedSHA256])
        return evidence
    }

    private static func checkedSource(_ text: String, evidence: SourceEvidence) throws -> Data {
        let bytes = Data((text + "\n").utf8)
        #expect(bytes.count == evidence.selectedByteCount)
        #expect(try SHA256ContentDigester().digest(data: bytes, using: .sha256).hexadecimalValue == evidence.selectedSHA256)
        var consumed = 0
        for range in evidence.ranges {
            let count = range.originEnd - range.originStart
            try #require(range.selectedStart == consumed && count > 0 && range.originEnd <= evidence.originByteCount)
            let piece = bytes.subdata(in: consumed..<(consumed + count))
            #expect(try SHA256ContentDigester().digest(data: piece, using: .sha256).hexadecimalValue == range.sha256)
            consumed += count
        }
        #expect(consumed == bytes.count)
        return bytes
    }

    private static let technologyEvidence = SourceEvidence(
        origin: originRoot + "techlef/sky130_fd_sc_hd__nom.tlef",
        originSHA256: "5de46c6f7c2cf82599b93d30a6459465f770f63c85b36182c672782219938519", originByteCount: 18167,
        selectedSHA256: "c211f6f460de59d15c893f7dacdb4b814d748de21cec625b506dfafec12dddcd", selectedByteCount: 2863,
        ranges: [
            .init(originStart: 0, originEnd: 1029, selectedStart: 0, sha256: "15736afba1374bd3f8a9e612449032f3e15a9cd7e8672a85b2b7be8f8faedc14"),
            .init(originStart: 1142, originEnd: 1224, selectedStart: 1029, sha256: "534ab94f0d6435d004c0f1deb4e7f28969bad922beba42a4d066c531cffce1d3"),
            .init(originStart: 1225, originEnd: 1307, selectedStart: 1111, sha256: "22f1a87ac650ebc36c3cbd9f9356a0e30a778376fa3ca91fdf5e0bd67b90f057"),
            .init(originStart: 1344, originEnd: 1829, selectedStart: 1193, sha256: "95e88299cdbb36e1422ef863856b064a3db54fa6478b554fce1ca11f2ff66cdc"),
            .init(originStart: 1830, originEnd: 2125, selectedStart: 1678, sha256: "b395e60f426af87472869719a0000565a0302acf27499aadbf908583126ce069"),
            .init(originStart: 2194, originEnd: 2204, selectedStart: 1973, sha256: "9ea959528be783e1cce3c15bcbbda82291c907729ba56ac84af5fb1427effb33"),
            .init(originStart: 2205, originEnd: 2777, selectedStart: 1983, sha256: "512f429a73070edc88cc32f1b32830d1f22b9b6bb6b8182e61853679171210f8"),
            .init(originStart: 2899, originEnd: 3014, selectedStart: 2555, sha256: "b409ac7ee459278bf9dbb074b4dc69b4728b9278d217d7de7cf9976fabc273a1"),
            .init(originStart: 7534, originEnd: 7715, selectedStart: 2670, sha256: "7d125296210623ce0b9faaf6431de0b42ce40e054e3199638416b39257d764e1"),
            .init(originStart: 18155, originEnd: 18167, selectedStart: 2851, sha256: "1b644ce0749ecfcdade8a36b32343c83c8e31e1ae6174d43ac8175b99ac67693")
        ], excludedFacts: ["Current-density/EM declarations excluded; no electrical signoff claim.", "Other source layers, sites, generated VIA rules and fixed VIA masters excluded."])

    private static let technologyText = #"""
    # Copyright 2020 The SkyWater PDK Authors
    #
    # Licensed under the Apache License, Version 2.0 (the "License");
    # you may not use this file except in compliance with the License.
    # You may obtain a copy of the License at
    #
    #     https://www.apache.org/licenses/LICENSE-2.0
    #
    # Unless required by applicable law or agreed to in writing, software
    # distributed under the License is distributed on an "AS IS" BASIS,
    # WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    # See the License for the specific language governing permissions and
    # limitations under the License.
    #
    # SPDX-License-Identifier: Apache-2.0

    VERSION 5.7 ;

    BUSBITCHARS "[]" ;
    DIVIDERCHAR "/" ;

    UNITS
      TIME NANOSECONDS 1 ;
      CAPACITANCE PICOFARADS 1 ;
      RESISTANCE OHMS 1 ;
      DATABASE MICRONS 1000 ;
    END UNITS

    MANUFACTURINGGRID 0.005 ;
    USEMINSPACING OBS OFF ;

    PROPERTYDEFINITIONS
      LAYER LEF58_TYPE STRING ;
    END PROPERTYDEFINITIONS

    # High density, single height
    SITE unithd
      SYMMETRY Y ;
      CLASS CORE ;
      SIZE 0.46 BY 2.72 ;
    END unithd
    LAYER nwell
      TYPE MASTERSLICE ;
      PROPERTY LEF58_TYPE "TYPE NWELL ;" ;
    END nwell
    LAYER pwell
      TYPE MASTERSLICE ;
      PROPERTY LEF58_TYPE "TYPE PWELL ;" ;
    END pwell
    LAYER li1
      TYPE ROUTING ;
      DIRECTION VERTICAL ;

      PITCH 0.46 0.34 ;
      OFFSET 0.23 0.17 ;

      WIDTH 0.17 ;          # LI 1
      # SPACING  0.17 ;     # LI 2
      SPACINGTABLE
         PARALLELRUNLENGTH 0
         WIDTH 0 0.17 ;
      AREA 0.0561 ;         # LI 6
      THICKNESS 0.1 ;
      EDGECAPACITANCE 40.697E-6 ;
      CAPACITANCE CPERSQDIST 36.9866E-6 ;
      RESISTANCE RPERSQ 12.8 ;

      ANTENNAMODEL OXIDE1 ;
      ANTENNADIFFSIDEAREARATIO PWL ( ( 0 75 ) ( 0.0125 75 ) ( 0.0225 85.125 ) ( 22.5 10200 ) ) ;
    END li1
    LAYER mcon
      TYPE CUT ;

      WIDTH 0.17 ;                # Mcon 1
      SPACING 0.19 ;              # Mcon 2
      ENCLOSURE BELOW 0 0 ;       # Mcon 4
      ENCLOSURE ABOVE 0.03 0.06 ; # Met1 4 / Met1 5
      RESISTANCE 9.30 ;

      ANTENNADIFFAREARATIO PWL ( ( 0 3 ) ( 0.0125 3 ) ( 0.0225 3.405 ) ( 22.5 408 ) ) ;

    END mcon
    LAYER met1
      TYPE ROUTING ;
      DIRECTION HORIZONTAL ;

      PITCH 0.34 ;
      OFFSET 0.17 ;

      WIDTH 0.14 ;                     # Met1 1
      # SPACING 0.14 ;                 # Met1 2
      # SPACING 0.28 RANGE 3.001 100 ; # Met1 3b
      SPACINGTABLE
         PARALLELRUNLENGTH 0
         WIDTH 0 0.14
         WIDTH 3 0.28 ;
      AREA 0.083 ;                     # Met1 6
      THICKNESS 0.35 ;
      MINENCLOSEDAREA 0.14 ;

      ANTENNAMODEL OXIDE1 ;
      ANTENNADIFFSIDEAREARATIO PWL ( ( 0 400 ) ( 0.0125 400 ) ( 0.0225 2609 ) ( 22.5 11600 ) ) ;

      EDGECAPACITANCE 40.567E-6 ;
      CAPACITANCE CPERSQDIST 25.7784E-6 ;
      MAXIMUMDENSITY 70 ;
      DENSITYCHECKWINDOW 700 700 ;
      DENSITYCHECKSTEP 70 ;

      RESISTANCE RPERSQ 0.125 ;
    END met1
    VIA L1M1_PR DEFAULT
      LAYER mcon ;
      RECT -0.085 -0.085 0.085 0.085 ;
      LAYER li1 ;
      RECT -0.085 -0.085 0.085 0.085 ;
      LAYER met1 ;
      RECT -0.145 -0.115 0.145 0.115 ;
    END L1M1_PR
    END LIBRARY
    """#

    private static let cellEvidence = SourceEvidence(
        origin: originRoot + "lef/sky130_fd_sc_hd.lef",
        originSHA256: "3a3ea4e9d0973402702764d897659e52fe3d413eb48c306cd811de40a75264fa", originByteCount: 1415362,
        selectedSHA256: "dcb37b5601eb47b7e5e1714ec3a0607fedd7034e2794edc39ed0934e02aba400", selectedByteCount: 1740,
        ranges: [
            .init(originStart: 0, originEnd: 14, selectedStart: 0, sha256: "3e48a0bd3d4e2e024d84c0d6fc335901bf73b695da1dd3dae85d58d9ae518f22"),
            .init(originStart: 42, originEnd: 83, selectedStart: 14, sha256: "5bb23cb28489e37d6e7533b8bdcf68a0ba7e882f1e9ab5b7c0ec9e6a92f4750e"),
            .init(originStart: 259291, originEnd: 260964, selectedStart: 55, sha256: "54833988096a6153335c75dc1a8671b3d2d16e5a06d978129be18cda4f9c415c"),
            .init(originStart: 1415350, originEnd: 1415362, selectedStart: 1728, sha256: "1b644ce0749ecfcdade8a36b32343c83c8e31e1ae6174d43ac8175b99ac67693")
        ], excludedFacts: ["NOWIREEXTENSIONATPIN ON excluded; explicit selected native routing profile only.", "All other original cell macros excluded; complete buf_1 macro retained."])

    private static let cellText = #"""
    VERSION 5.7 ;
      DIVIDERCHAR "/" ;
      BUSBITCHARS "[]" ;
    MACRO sky130_fd_sc_hd__buf_1
      CLASS CORE ;
      FOREIGN sky130_fd_sc_hd__buf_1 ;
      ORIGIN 0.000 0.000 ;
      SIZE 1.380 BY 2.720 ;
      SYMMETRY X Y R90 ;
      SITE unithd ;
      PIN A
        DIRECTION INPUT ;
        USE SIGNAL ;
        ANTENNAGATEAREA 0.196500 ;
        PORT
          LAYER li1 ;
            RECT 0.105 0.985 0.445 1.355 ;
        END
      END A
      PIN VGND
        DIRECTION INOUT ;
        USE GROUND ;
        SHAPE ABUTMENT ;
        PORT
          LAYER met1 ;
            RECT 0.000 -0.240 1.380 0.240 ;
        END
      END VGND
      PIN VNB
        DIRECTION INOUT ;
        USE GROUND ;
        PORT
          LAYER pwell ;
            RECT 0.005 0.105 1.375 0.885 ;
            RECT 0.155 -0.085 0.325 0.105 ;
        END
      END VNB
      PIN VPB
        DIRECTION INOUT ;
        USE POWER ;
        PORT
          LAYER nwell ;
            RECT -0.190 1.305 1.570 2.910 ;
        END
      END VPB
      PIN VPWR
        DIRECTION INOUT ;
        USE POWER ;
        SHAPE ABUTMENT ;
        PORT
          LAYER met1 ;
            RECT 0.000 2.480 1.380 2.960 ;
        END
      END VPWR
      PIN X
        DIRECTION OUTPUT ;
        USE SIGNAL ;
        ANTENNADIFFAREA 0.340600 ;
        PORT
          LAYER li1 ;
            RECT 1.025 1.560 1.295 2.465 ;
            RECT 1.115 0.760 1.295 1.560 ;
            RECT 1.035 0.255 1.295 0.760 ;
        END
      END X
      OBS
          LAYER li1 ;
            RECT 0.000 2.635 1.380 2.805 ;
            RECT 0.165 1.705 0.345 2.465 ;
            RECT 0.525 1.875 0.855 2.635 ;
            RECT 0.165 1.535 0.840 1.705 ;
            RECT 0.670 1.390 0.840 1.535 ;
            RECT 0.670 1.060 0.945 1.390 ;
            RECT 0.670 0.805 0.840 1.060 ;
            RECT 0.175 0.635 0.840 0.805 ;
            RECT 0.175 0.255 0.345 0.635 ;
            RECT 0.525 0.085 0.855 0.465 ;
            RECT 0.000 -0.085 1.380 0.085 ;
      END
    END sky130_fd_sc_hd__buf_1
    END LIBRARY
    """#
}
