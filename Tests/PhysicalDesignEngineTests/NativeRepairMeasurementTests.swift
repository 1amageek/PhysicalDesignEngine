import Foundation
import Testing
import CircuiteFoundation
import DRCNative
import PDKCore
import PhysicalDesignEngine
@testable import PhysicalDesignCore

@Suite("Source-bound native repair measurement", .timeLimit(.minutes(2)))
struct NativeRepairMeasurementTests {
    @Test("actual antenna geometry is repaired under the exact native law", arguments: [PhysicalDesignAntennaRepairStrategy.reroute, .jumper, .protectionDevice])
    func antenna(_ strategy: PhysicalDesignAntennaRepairStrategy) async throws {
        let (request, store, geometry) = try await fixture(antenna: strategy)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        guard result.status == .completed else { return }
        let output = try await snapshot(result, store: store)
        #expect(output.routes != request.initialSnapshot?.routes)
        #expect(output.antennaRepairs.last?.resultingRatio == nil)
        #expect(output.antennaRepairs.last?.ratioStatus == .unavailableFromNativeRuleVerdict)
        #expect(output.nets.first?.antennaRatio == nil)
        #expect(output.implementationState?.repairProofs.last?.verified == true)
        if strategy == .jumper { #expect(output.routes.flatMap(\.segments).contains { $0.layer == 5 }) }
        if strategy == .protectionDevice { #expect(output.cells.contains { $0.master == "DIODE" }) }
        try geometry.validate(output)
        try await verifyEvidence(result, request: request, store: store)
    }

    @Test("declared NativeDRC cut, cumulative and sidewall laws remain executable", arguments: ["cut-stage", "cumulative", "sidewall"])
    func existingLaws(_ model: String) async throws {
        let (request, store, _) = try await fixture(antenna: .reroute, failure: model)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        guard result.status == .completed else { return }
        try await verifyEvidence(result, request: request, store: store)
    }

    @Test("protection realizes every source pin and preserves all touched nets", arguments: [false, true])
    func protectionInterface(_ openBias: Bool) async throws {
        let (request, store, _) = try await fixture(antenna: .protectionDevice, failure: openBias ? "protection-bias-open" : "protection-bias")
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        if openBias {
            #expect(result.status == .blocked && result.artifactBindings.isEmpty)
            #expect(result.diagnostics.contains { $0.code.rawValue == "repair_measurement_failed" && $0.summary.contains("physical open") }, "\(result.diagnostics)")
        } else {
            #expect(result.status == .completed, "\(result.diagnostics)")
            guard result.status == .completed else { return }
            let output = try await snapshot(result, store: store)
            #expect(output.nets.first { $0.id == "bias" }?.pinIDs.count == 3)
            #expect(output.routes.contains { $0.netID == "bias" })
            try await verifyEvidence(result, request: request, store: store)
        }
    }

    @Test("hotspot resolution requires the selected geometry's actual rule verdict", arguments: ["spacing", "density", "cut"])
    func hotspot(_ kind: String) async throws {
        let (request, store, _) = try await fixture(hotspot: kind)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        guard result.status == .completed else { return }
        let output = try await snapshot(result, store: store)
        #expect(output.hotspots.first?.resolved == true)
        #expect(output.hotspots.first?.resolution == "exact_native_rule_verdict")
        #expect(output.routes != request.initialSnapshot?.routes || output.vias != request.initialSnapshot?.vias || output.fills != request.initialSnapshot?.fills)
        try await verifyEvidence(result, request: request, store: store)
    }

    @Test("exact measurement refusals publish no candidate", arguments: ["budget", "aggregate", "numeric", "gate", "cut", "filter", "no-change", "unrelated", "scalar", "remaining", "open"])
    func refusal(_ kind: String) async throws {
        var (request, store, geometry) = try await fixture(antenna: .reroute, failure: kind)
        if kind == "budget" {
            request.repairMeasurementProfile = .init(artifact: try #require(request.repairMeasurementProfile?.artifact),
                limits: .init(maximumInputBytes: 8_000_000, maximumProjectionRecords: 10_000, maximumGeometryProbes: 2_000_000, maximumBackendWork: 1, timeoutSeconds: 30))
        }
        if kind == "aggregate" {
            let profile = try PhysicalDesignJSONCodec().decode(PhysicalDesignRepairMeasurementProfile.self, from: await store.read(try #require(request.repairMeasurementProfile?.artifact)))
            let projection = try PhysicalDesignRepairProjection(snapshot: try #require(request.initialSnapshot), geometry: geometry, profile: profile,
                limits: try #require(request.repairMeasurementProfile?.limits), requireGateFacts: true)
            let count = try projection.layout(rule: profile.rules[0]).rectangles.count
            request.repairMeasurementProfile = .init(artifact: try #require(request.repairMeasurementProfile?.artifact),
                limits: .init(maximumInputBytes: 8_000_000, maximumProjectionRecords: 10_000, maximumGeometryProbes: 2_000_000,
                    maximumBackendWork: count * count * count + 1, timeoutSeconds: 30))
        }
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
        let expected = kind == "numeric" ? "physical_technology_unsupported" : "repair_measurement_failed"
        #expect(result.diagnostics.contains { $0.code.rawValue == expected }, "\(result.diagnostics)")
        let reason = ["budget": "work admission", "aggregate": "work admission", "remaining": "retains required native rule violations", "open": "physical open", "numeric": "not numerical ratios", "gate": "ANTENNAGATEAREA", "cut": "cut relations", "filter": "omit any target gate", "no-change": "no actual before violation", "unrelated": "gate coverage", "scalar": "Legacy scalar limits"][kind]!
        #expect(result.diagnostics.contains { $0.summary.contains(reason) }, "\(result.diagnostics)")
        #expect(await store.data(at: "runs/\(request.runID)/physical-design/antenna_repair/revision.json") == nil)
        #expect(request.initialSnapshot?.nets.first?.antennaRatio == 999)
    }

    @Test("hotspot candidates cannot resolve unrelated or remaining violations", arguments: ["hotspot-unrelated", "hotspot-alias", "hotspot-remaining"])
    func hotspotRefusal(_ failure: String) async throws {
        let (request, store, _) = try await fixture(hotspot: "density", failure: failure)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
        let reason = failure != "hotspot-remaining" ? "Hotspot has no before violation" : "retains required native rule violations"
        #expect(result.diagnostics.contains { $0.code.rawValue == "repair_measurement_failed" && $0.summary.contains(reason) }, "\(result.diagnostics)")
        #expect(request.initialSnapshot?.hotspots.first?.resolved == false)
    }

    @Test("actual CLI retains native raw measurement or the same candidate failure", arguments: ["antenna", "density", "budget"])
    func actualCLI(_ kind: String) async throws {
        var (request, memory, _) = try await fixture(antenna: kind == "density" ? nil : .reroute, hotspot: kind == "density" ? "density" : nil)
        if kind == "budget" {
            request.repairMeasurementProfile = .init(artifact: try #require(request.repairMeasurementProfile?.artifact),
                limits: .init(maximumInputBytes: 8_000_000, maximumProjectionRecords: 10_000, maximumGeometryProbes: 2_000_000, maximumBackendWork: 1, timeoutSeconds: 30))
        }
        let retained = ProcessInfo.processInfo.environment["LSI_PHYSICAL_S3_EVIDENCE_ROOT"]
        let root = retained.map { URL(fileURLWithPath: $0).appending(path: "measurement-cli-\(kind)") }
            ?? FileManager.default.temporaryDirectory.appending(path: "measurement-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if retained == nil { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } } }
        for binding in request.inputBindings {
            let path = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: path)
        }
        let path = root.appending(path: "request.json"); try PhysicalDesignJSONCodec().encode(request).write(to: path)
        let process = Process(); process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", path.path, "--project-root", root.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try bytes.write(to: root.appending(path: "cli-result.json"))
        try JSONSerialization.data(withJSONObject: ["executable": process.executableURL!.path, "arguments": process.arguments!, "exit": process.terminationStatus], options: [.prettyPrinted, .sortedKeys]).write(to: root.appending(path: "cli-command.json"))
        let result = try PhysicalDesignJSONCodec().decode(PhysicalDesignResult.self, from: bytes)
        if kind == "budget" {
            #expect(process.terminationStatus != 0 && result.status == .blocked && result.artifactBindings.isEmpty)
            #expect(result.diagnostics.contains { $0.code.rawValue == "repair_measurement_failed" })
        } else {
            #expect(process.terminationStatus == 0 && result.status == .completed, "\(result.diagnostics)")
            try await verifyEvidence(result, request: request, store: FileSystemPhysicalDesignArtifactStore(projectRoot: root))
        }
    }

    private func snapshot(_ result: PhysicalDesignResult, store: any PhysicalDesignArtifactStore) async throws -> PhysicalDesignSnapshot {
        try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
    }

    private func verifyEvidence(_ result: PhysicalDesignResult, request: PhysicalDesignRequest, store: any PhysicalDesignArtifactStore) async throws {
        let binding = try #require(result.artifactBindings.first { $0.logicalID.hasSuffix("manifest") })
        let manifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self, from: await store.read(binding))
        let evidence = try #require(manifest.repairMeasurementEvidence)
        #expect(manifest.validationDiagnostics().isEmpty)
        #expect(evidence.profile == request.repairMeasurementProfile?.artifact.reference)
        #expect(evidence.afterSnapshotDigest == result.payload.physicalDesign?.layoutArtifact.reference.digest)
        #expect(evidence.checks.contains { $0.before.result.diagnostics.contains { $0.severity == .error } })
        #expect(evidence.checks.allSatisfy { $0.after.result.completed && $0.after.result.success && $0.beforeLayout.rules == $0.afterLayout.rules })
        for check in evidence.checks {
            #expect(check.beforeLayout.technologyID == request.pdk.manifest.id.description)
            let root = FileManager.default.temporaryDirectory.appending(path: "repair-replay-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
            for (name, layout, expected) in [("before", check.beforeLayout, check.before.result.diagnostics), ("after", check.afterLayout, check.after.result.diagnostics)] {
                let path = root.appending(path: name + ".json"); try PhysicalDesignJSONCodec().encode(layout).write(to: path)
                let replay = try await NativeDRCBackend().run(.init(layoutURL: path, topCell: layout.topCell, layoutFormat: .nativeJSON,
                    backendSelection: .init(backendID: "native"), options: .init(timeoutSeconds: 30, requireAntennaRules: request.stage == .antennaRepair)))
                #expect(replay.result.completed && replay.result.success)
                #expect(replay.result.diagnostics == expected)
            }
        }
    }

    private func segment(_ id: String, _ layer: Int, _ x1: Int64, _ y1: Int64, _ x2: Int64, _ y2: Int64) -> PhysicalDesignSnapshot.RouteSegment {
        .init(id: id, layer: layer, x1: x1, y1: y1, x2: x2, y2: y2, widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))
    }

    func fixture(antenna: PhysicalDesignAntennaRepairStrategy? = nil, hotspot: String? = nil, failure: String? = nil, sourceLaw: String? = nil)
        async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore, PhysicalDesignProcessGeometry) {
        let store = InMemoryPhysicalDesignArtifactStore()
        var technology = """
        VERSION 5.8 ; UNITS DATABASE MICRONS 1000 ; END UNITS
        LAYER metH TYPE ROUTING ; DIRECTION HORIZONTAL ; PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ; END metH
        LAYER cutHV TYPE CUT ; WIDTH 0.05 ; SPACING 0.05 ; END cutHV
        LAYER metV TYPE ROUTING ; DIRECTION VERTICAL ; PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ; END metV
        LAYER cutVU TYPE CUT ; WIDTH 0.05 ; SPACING 0.05 ; END cutVU
        LAYER metU TYPE ROUTING ; DIRECTION HORIZONTAL ; PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ; END metU
        SITE unit CLASS CORE ; SIZE 0.1 BY 1 ; SYMMETRY X Y ; END unit
        VIA hv DEFAULT LAYER metH ; RECT -0.1 -0.1 0.1 0.1 ; LAYER cutHV ; RECT -0.025 -0.025 0.025 0.025 ; LAYER metV ; RECT -0.1 -0.1 0.1 0.1 ; END hv
        VIA vu DEFAULT LAYER metV ; RECT -0.1 -0.1 0.1 0.1 ; LAYER cutVU ; RECT -0.025 -0.025 0.025 0.025 ; LAYER metU ; RECT -0.1 -0.1 0.1 0.1 ; END vu
        END LIBRARY
        """
        var cells = """
        VERSION 5.8 ; UNITS DATABASE MICRONS 1000 ; END UNITS
        MACRO SRC CLASS CORE ; SIZE 0.4 BY 1 ; SYMMETRY X Y ; SITE unit ;
          PIN Y DIRECTION OUTPUT ; USE SIGNAL ; ANTENNADIFFAREA 0 ; PORT LAYER metH ; RECT 0.05 0.05 0.35 0.35 ; END END Y
        END SRC
        MACRO GATE CLASS CORE ; SIZE 0.4 BY 1 ; SYMMETRY X Y ; SITE unit ;
          PIN A DIRECTION INPUT ; USE SIGNAL ; ANTENNAGATEAREA 0.05 ; ANTENNADIFFAREA 0 ; PORT LAYER metH ; RECT 0.05 0.05 0.35 0.35 ; END END A
        END GATE
        MACRO DIODE CLASS CORE ; SIZE 0.4 BY 1 ; SYMMETRY X Y ; SITE unit ;
          PIN D DIRECTION INOUT ; USE SIGNAL ; ANTENNADIFFAREA 0.5 ; PORT LAYER metH ; RECT 0.05 0.05 0.35 0.35 ; END END D
        END DIODE END LIBRARY
        """
        if let sourceLaw {
            let law = sourceLaw == "domain" || sourceLaw == "pwl" ? "PWL ( ( 0 20 ) ( 0.1 40 ) )" : sourceLaw == "clean" || sourceLaw == "multiport" ? "1000" : sourceLaw == "violated" ? "5" : sourceLaw == "repair" ? "18" : "20"
            let statement = sourceLaw == "model-only" ? "ANTENNAMODEL OXIDE1 ;" : "ANTENNADIFFAREARATIO \(law) ;"
            technology = technology.replacingOccurrences(of: "SPACING 0.1 ; END metH", with: "SPACING 0.1 ; \(statement) END metH")
            cells = cells.replacingOccurrences(of: "ANTENNADIFFAREA 0 ;", with: "")
            if sourceLaw == "gate" { cells = cells.replacingOccurrences(of: "ANTENNAGATEAREA 0.05 ;", with: "") }
            if sourceLaw == "domain" || sourceLaw == "pwl" {
                cells = cells.replacingOccurrences(of: "ANTENNAGATEAREA 0.05 ;", with: "ANTENNAGATEAREA 0.05 ; ANTENNADIFFAREA \(sourceLaw == "domain" ? "23" : "0.1") ;")
            }
            if sourceLaw == "well" || sourceLaw == "target-well" {
                technology = technology.replacingOccurrences(of: "END LIBRARY", with: "LAYER pwell TYPE MASTERSLICE ; END pwell END LIBRARY")
                if sourceLaw == "well" {
                    cells = cells.replacingOccurrences(of: "END GATE", with: "PIN W DIRECTION INOUT ; USE GROUND ; PORT LAYER pwell ; RECT 0 0 0.4 1 ; END END W END GATE")
                } else {
                    cells = cells.replacingOccurrences(of: "END END A", with: "END PORT LAYER pwell ; RECT 0.05 0.05 0.35 0.35 ; END END A")
                }
            }
            if sourceLaw == "multiport" {
                cells = cells.replacingOccurrences(of: "END END A", with: "END PORT LAYER metH ; RECT 0.05 0.05 0.35 0.35 ; END END A")
            }
        }
        if failure?.hasPrefix("protection-bias") == true {
            cells = cells.replacingOccurrences(of: "END DIODE END LIBRARY", with: "PIN B DIRECTION INOUT ; USE SIGNAL ; PORT LAYER metU ; RECT 0.05 0.05 0.35 0.35 ; END END B\nEND DIODE END LIBRARY")
        }
        if failure == "gate" { cells = cells.replacingOccurrences(of: "ANTENNAGATEAREA 0.05 ;", with: "") }
        let tech = try await store.registerInput(Data(technology.utf8), relativePath: "inputs/tech.lef", kind: .technology, format: .lef)
        let masters = try await store.registerInput(Data(cells.utf8), relativePath: "inputs/cells.lef", kind: .technology, format: .lef)
        var layers: [PDKLayerDefinition] = [("H", "metH", 2, true), ("V", "metV", 3, true), ("C", "cutHV", 4, false), ("U", "metU", 5, true), ("D", "cutVU", 6, false)].map {
            .init(layerID: $0.0, name: $0.1, number: $0.2, purpose: $0.3 ? .metal : .via, isRoutingLayer: $0.3)
        }
        if sourceLaw == "well" || sourceLaw == "target-well" {
            layers.append(.init(layerID: "WELL", name: "pwell", number: 7, purpose: .well))
        }
        let manifest = PDKManifest(processID: "measurement-fixture", version: "1", assets: [
            .init(assetID: "tech", role: .technology, path: "tech.lef", kind: .technology, format: .lef, sha256: tech.reference.digest.hexadecimalValue, byteCount: Int64(technology.utf8.count)),
            .init(assetID: "cells", role: .cell, path: "cells.lef", kind: .technology, format: .lef, sha256: masters.reference.digest.hexadecimalValue, byteCount: Int64(cells.utf8.count))
        ], layers: layers, crossViewMappings: [
            .init(mappingID: "tech", view: .lef, assetID: "tech", layerIDs: layers.map(\.layerID)),
            .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: ["SRC", "GATE", "DIODE"], layerIDs: layers.map(\.layerID))
        ])
        let process = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        var input = PhysicalDesignSnapshot(topCell: "fixture_top", unitsPerMicron: 1000, die: .init(x: 0, y: 0, width: 10000, height: 5000), core: .init(x: 0, y: 0, width: 10000, height: 5000),
            rows: (0..<5).map { .init(id: "row-\($0)", originX: 0, originY: Int64($0 * 1000), siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit") })
        var rules: [NativeDRCRule], constraints: [PhysicalDesignHotspotConstraint] = []
        if let antenna {
            input.cells = [.init(id: "S", master: "SRC", x: 1000, y: 1000, width: 400, height: 1000, placed: true),
                .init(id: "G", master: "GATE", x: 7000, y: 1000, width: 400, height: 1000, placed: true)]
            input.pins = [.init(id: "S/Y", cellID: "S", name: "Y", netID: "N"), .init(id: "G/A", cellID: "G", name: "A", netID: "N")]
            input.nets = [.init(id: "N", pinIDs: input.pins.map(\.id), antennaRatio: 999)]
            input.routes = [.init(id: "original", netID: "N", segments: [segment("direct", 2, 1100, 1100, 7300, 1100), segment("branch-v", 3, 3100, 1100, 3100, 3100), segment("branch-h", 2, 1100, 3100, 9500, 3100)])]
            input.vias = [.init(id: "v1", netID: "N", x: 3100, y: 1100, lowerLayer: 2, upperLayer: 3, master: "hv"), .init(id: "v2", netID: "N", x: 3100, y: 3100, lowerLayer: 2, upperLayer: 3, master: "hv")]
            if sourceLaw == "repair" || sourceLaw == "twenty" {
                input.routes[0].segments[0] = segment("direct", 2, 1100, 1100, 9500, 1100)
            }
            if sourceLaw == "top" {
                input.pins.append(.init(id: "external", cellID: nil, name: "external", x: 1100, y: 1100, netID: "N", direction: "input", accessLayer: 2,
                    topPort: .init(rectangle: .init(x: -50, y: -50, width: 100, height: 100), layer: 2, placementX: 1100, placementY: 1100,
                        orientation: .n, placementStatus: .fixed, use: .signal)))
                input.nets[0].pinIDs.append("external")
            }
            if failure == "open" { input.vias.removeAll() }
            let limit: Double = failure == "remaining" ? 5 : 20
            if failure == "no-change" { input.routes[0].segments = [segment("direct", 2, 1100, 1100, 7300, 1100)]; input.vias = [] }
            rules = [.init(id: "antenna-H", kind: .maximumAntennaRatio, layer: "metH", value: limit, gateLayer: failure == "filter" ? "metU" : "metH", processStep: "etch-H",
                antennaCutConnections: failure == "cut" ? [.init(layer: "cutHV", lowerLayer: "metH", upperLayer: "metV")] : nil,
                antennaModel: .partial, antennaLayers: [.init(layer: "metH", measurement: .surface, ratioGate: limit,
                    diffusionCorrection: antenna == .protectionDevice ? .finite : .none,
                    diffusionRatioConstant: antenna == .protectionDevice ? 0 : nil, diffusionRatioPerArea: antenna == .protectionDevice ? 100 : nil)])]
            if failure == "cut-stage" {
                input.routes[0].segments = [segment("direct", 2, 1100, 1100, 7300, 1100)]
                input.vias = [.init(id: "cut-one", netID: "N", x: 7100, y: 1100, lowerLayer: 2, upperLayer: 3, master: "hv"),
                    .init(id: "cut-two", netID: "N", x: 7300, y: 1100, lowerLayer: 2, upperLayer: 3, master: "hv")]
                rules = [.init(id: "cut-stage", kind: .maximumAntennaRatio, layer: "cutHV", value: 0.07, gateLayer: "metH", processStep: "etch-cut",
                    antennaCutConnections: [.init(layer: "cutHV", lowerLayer: "metH", upperLayer: "metV")], antennaModel: .partial,
                    antennaLayers: [.init(layer: "cutHV", measurement: .surface, ratioGate: 0.07, diffusionCorrection: .none)])]
            }
            if failure == "cumulative" {
                rules = [.init(id: "cumulative", kind: .maximumAntennaRatio, layer: "metV", value: 20, gateLayer: "metH", processStep: "etch-V",
                    antennaCutConnections: [.init(layer: "cutHV", lowerLayer: "metH", upperLayer: "metV")], antennaModel: .cumulative,
                    antennaLayers: [.init(layer: "metH", measurement: .surface, ratioGate: 20, diffusionCorrection: .none),
                        .init(layer: "metV", measurement: .surface, ratioGate: 20, diffusionCorrection: .none)])]
            }
            if failure == "sidewall" {
                rules = [.init(id: "sidewall", kind: .maximumAntennaRatio, layer: "metH", value: 40, gateLayer: "metH", processStep: "etch-H",
                    antennaModel: .partial, antennaLayers: [.init(layer: "metH", measurement: .sidewall, ratioGate: 40, thickness: 0.1, diffusionCorrection: .none)])]
            }
            if failure?.hasPrefix("protection-bias") == true {
                input.nets.append(.init(id: "bias", pinIDs: ["bias-a", "bias-b"]))
                for (id, x) in [("bias-a", 1100), ("bias-b", 8900)] {
                    input.pins.append(.init(id: id, cellID: nil, name: id, x: Int64(x), y: 4100, netID: "bias", direction: "inout", accessLayer: 5,
                        topPort: .init(rectangle: .init(x: -50, y: -50, width: 100, height: 100), layer: 5, placementX: Int64(x), placementY: 4100, orientation: .n, placementStatus: .fixed, use: .signal)))
                }
                if failure != "protection-bias-open" { input.routes.append(.init(id: "bias-wire", netID: "bias", segments: [segment("bias-wire", 5, 1100, 4100, 8900, 4100)])) }
            }
            if failure == "unrelated" { input.nets.append(.init(id: "untouched", pinIDs: [])) }
        } else {
            let rect: PhysicalDesignSnapshot.Rect
            switch hotspot {
            case "density":
                rect = .init(x: 2000, y: 1000, width: 4000, height: 4000)
                input.fills = [.init(id: "F", layer: 2, geometry: rect), .init(id: "retained", layer: 5, geometry: .init(x: 100, y: 100, width: 100, height: 100))]
                rules = [.init(id: "density-H", kind: .maximumDensity, layer: "metH", value: 0.5, windowWidth: 4, windowHeight: 4, windowOriginX: 2, windowOriginY: 1)]
                if failure == "hotspot-remaining" { input.fills[1] = .init(id: "retained", layer: 2, geometry: .init(x: 2000, y: 1000, width: 4000, height: 3000)) }
                constraints = [.init(hotspotID: "H", predicate: .fillDensity(ruleID: "density-H", targetFillIDs: [failure == "hotspot-unrelated" ? "retained" : "F"]))]
                if failure == "hotspot-alias" {
                    input.fills[0] = .init(id: "F", layer: 2, geometry: .init(x: 100, y: 100, width: 100, height: 100))
                    input.fills.append(.init(id: "F:alias", layer: 2, geometry: rect))
                    constraints.append(.init(hotspotID: "H2", predicate: .fillDensity(ruleID: "density-H", targetFillIDs: ["F:alias"])))
                }
            case "cut":
                rect = .init(x: 4700, y: 2300, width: 600, height: 400)
                input.nets = [.init(id: "N", pinIDs: [])]
                input.routes = [.init(id: "wire", netID: "N", segments: [segment("h", 2, 1000, 2500, 9000, 2500), segment("v", 3, 4900, 1000, 4900, 4500)])]
                input.vias = [.init(id: "primary", netID: "N", x: 4900, y: 2500, lowerLayer: 2, upperLayer: 3, master: "hv"),
                    .init(id: "redundant", netID: "N", x: 5000, y: 2500, lowerLayer: 2, upperLayer: 3, isRedundant: true, master: "hv")]
                rules = [.init(id: "spacing-cut", kind: .minimumSpacing, layer: "cutHV", value: 0.1)]
                constraints = [.init(hotspotID: "H", predicate: .viaCutSpacing(ruleID: "spacing-cut", targetViaIDs: ["redundant"]))]
            default:
                rect = .init(x: 2000, y: 2800, width: 6000, height: 300)
                input.nets = [.init(id: "N", pinIDs: ["a", "b"]), .init(id: "other", pinIDs: ["c", "d"])]
                for (id, net, x, y) in [("a", "N", 1100, 2500), ("b", "N", 8900, 2500), ("c", "other", 1100, 3300), ("d", "other", 8900, 3300)] {
                    input.pins.append(.init(id: id, cellID: nil, name: id, x: Int64(x), y: Int64(y), netID: net, direction: "inout", accessLayer: 2,
                        topPort: .init(rectangle: .init(x: -50, y: -50, width: 100, height: 100), layer: 2, placementX: Int64(x), placementY: Int64(y), orientation: .n, placementStatus: .fixed, use: .signal)))
                }
                input.routes = [.init(id: "bad", netID: "N", segments: [segment("left", 3, 1100, 2500, 1100, 3100), segment("near", 2, 1100, 3100, 8900, 3100), segment("right", 3, 8900, 2500, 8900, 3100)]),
                    .init(id: "fixed", netID: "other", segments: [segment("other", 2, 1100, 3300, 8900, 3300)])]
                for (id, x, y) in [("a", 1100, 2500), ("b", 8900, 2500), ("e", 1100, 3100), ("f", 8900, 3100)] {
                    input.vias.append(.init(id: id, netID: "N", x: Int64(x), y: Int64(y), lowerLayer: 2, upperLayer: 3, master: "hv"))
                }
                rules = [.init(id: "spacing-H", kind: .minimumSpacing, layer: "metH", value: 0.25, spacingNetScope: .differentNet)]
                constraints = [.init(hotspotID: "H", predicate: .metalSpacing(ruleID: "spacing-H", targetNetIDs: ["N"]))]
            }
            input.hotspots = [.init(id: "H", geometry: rect, severity: "error")]
            if failure == "hotspot-alias" { input.hotspots.append(.init(id: "H2", geometry: rect, severity: "error")) }
        }
        let design = try await store.registerInput(try PhysicalDesignJSONCodec().encode(input), relativePath: "inputs/design.json", kind: .netlist, format: .json)
        let sdc = try await store.registerInput(Data("# Geometry rule repair\n".utf8), relativePath: "inputs/design.sdc", kind: .constraint, format: .sdc)
        let profile = PhysicalDesignRepairMeasurementProfile(processManifest: process.reference, processAssets: ["tech": tech.reference, "cells": masters.reference],
            processLayerOrder: sourceLaw != nil || failure == "cut-stage" || failure == "cumulative" ? ["metH", "cutHV", "metV", "cutVU", "metU"] : ["metH", "metV", "metU"], rules: sourceLaw == nil ? rules : [],
            antennaNetIDs: antenna == nil ? [] : failure == "unrelated" ? ["N", "untouched"] : ["N"], hotspots: constraints,
            protection: antenna == .protectionDevice ? .init(master: "DIODE", diffusionPin: "D", otherPinNetIDs: failure?.hasPrefix("protection-bias") == true ? ["B": "bias"] : [:]) : nil,
            requireNumericalAntennaRatio: failure == "numeric", antennaLimitPolicy: sourceLaw != nil ? .sourceProcessLaws : (antenna == .protectionDevice || failure == "cumulative") && failure != "scalar" ? .nativeRuleVerdict : .legacyScalarLimit)
        let measurement = try await store.registerInput(try PhysicalDesignJSONCodec().encode(profile), relativePath: "inputs/measurement.json", kind: .technology, format: .json)
        var configuration = PhysicalDesignConfiguration(dieWidth: 10000, dieHeight: 5000, coreMargin: 0, rowHeight: 1000, siteWidth: 100,
            preferredRoutingLayers: [2, 3, 5], maximumRoutingLayer: 5, powerNetNames: ["VDD"], maximumAntennaRatio: failure == "scalar" ? 19 : failure == "remaining" ? 5 : failure == "cut-stage" ? 0.07 : failure == "sidewall" ? 40 : 20,
            implementationConstraints: .init(routeWidth: 100, routeSpacing: hotspot == "spacing" ? 300 : 100))
        configuration.repairConstraints = .init(antennaStrategy: antenna ?? .reroute)
        var request = PhysicalDesignRequest(runID: "measurement-\(antenna?.rawValue ?? hotspot ?? "fixture")-\(failure ?? "valid")", inputBindings: [process, design, sdc],
            design: .init(artifact: design.reference, topDesignName: "fixture_top", designDigest: design.reference.digest.hexadecimalValue), constraints: sdc,
            requestedModeIDs: ["functional"], pdk: try .init(manifest: process.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: process), processID: "measurement-fixture", version: "1"),
            stage: antenna == nil ? .hotspotRepair : .antennaRepair, configuration: configuration, initialSnapshot: input,
            processAssets: ["tech": tech, "cells": masters], repairMeasurementProfile: .init(artifact: measurement,
                limits: .init(maximumInputBytes: 8_000_000, maximumProjectionRecords: 10_000, maximumGeometryProbes: 2_000_000, maximumBackendWork: 2_000_000, timeoutSeconds: 30)))
        #expect(request.configuration.validationDiagnostics().isEmpty)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        for index in input.pins.indices {
            if let cell = input.cells.first(where: { $0.id == input.pins[index].cellID }) {
                input.pins[index] = try geometry.referencePin(input.pins[index], for: cell)
            }
        }
        request.initialSnapshot = try PhysicalDesignTechnologyConstraints.prepare(geometry.bind(input), request: request, processInputs: inputs)
        try geometry.validate(try #require(request.initialSnapshot))
        #expect(request.initialSnapshot?.validationDiagnostics().isEmpty == true)
        return (request, store, geometry)
    }
}
