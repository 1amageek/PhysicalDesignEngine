import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import LEF
import PDKCore
import PhysicalDesignEngine
import STAEngine
import Testing
import TimingCore
@testable import PhysicalDesignCore

/// Actual selected source and host execution; no whole-PDK or post-route qualification.
@Suite("Actual Sky130 source-bound sequential placement", .serialized, .timeLimit(.minutes(2)))
struct ActualSky130SequentialPlacementTests {
    private static let master = "sky130_fd_sc_hd__dfxtp_1"
    private static let corner = "tt_025C_1v80"
    private let codec = PhysicalDesignJSONCodec()

    @Test("Actual source coefficients, sequential checks and propagated clocks survive API and CLI reload")
    func actualPlacementAPIAndCLI() async throws {
        let fixture = try await fixture()
        let retained = ProcessInfo.processInfo.environment["LSI_PHYSICAL_S3_EVIDENCE_ROOT"]
        let root = retained.map { URL(fileURLWithPath: $0).appending(path: "actual-sky130-sequential-placement") }
            ?? FileManager.default.temporaryDirectory.appending(path: "actual-sky130-sequential-placement-\(UUID().uuidString)")
        try #require(!FileManager.default.fileExists(atPath: root.path))
        defer {
            if retained == nil { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        }
        let apiRoot = root.appending(path: "api"), cliRoot = root.appending(path: "cli")
        for directory in [apiRoot, cliRoot] {
            for binding in fixture.request.inputBindings {
                let target = directory.appending(path: binding.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bytes = try await fixture.store.read(binding)
                try bytes.write(to: target)
            }
            try codec.encode(fixture.request).write(to: directory.appending(path: "request.json"))
        }
        let api = try await PhysicalDesignEngine(artifactStore: FileSystemPhysicalDesignArtifactStore(projectRoot: apiRoot)).execute(fixture.request)
        try codec.encode(api).write(to: apiRoot.appending(path: "api-result.json"))
        try #require(api.status == .completed, "\(api.diagnostics)")
        let first = try await verify(api, fixture: fixture, root: apiRoot)

        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", cliRoot.appending(path: "request.json").path, "--project-root", cliRoot.path]
        let outputURL = cliRoot.appending(path: "cli-result.json")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { do { try output.close() } catch { Issue.record(error) } }
        process.standardOutput = output
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning {
            process.terminate()
            let grace = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning && ContinuousClock.now < grace { try await Task.sleep(for: .milliseconds(10)) }
            throw CocoaError(.executableRuntimeMismatch)
        }
        process.waitUntilExit()
        let command: [String: Any] = ["executable": try #require(process.executableURL).path,
            "arguments": try #require(process.arguments), "exit": process.terminationStatus]
        try JSONSerialization.data(withJSONObject: command, options: [.prettyPrinted, .sortedKeys])
            .write(to: cliRoot.appending(path: "cli-command.json"))
        let cli = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: outputURL))
        try #require(process.terminationStatus == 0 && cli.status == .completed, "\(cli.diagnostics)")
        let second = try await verify(cli, fixture: fixture, root: cliRoot)
        #expect(first.snapshotDigest == second.snapshotDigest)
        #expect(first.timingDesignReference == second.timingDesignReference && first.rcInput == second.rcInput)
        #expect(first.result.payload.sourceEvidence == second.result.payload.sourceEvidence)
        #expect(first.result.payload.worstSetupSlack == second.result.payload.worstSetupSlack)

        var production = fixture.request
        production.runID += "-production-refusal"; production.executionIntent = .productionImplementation
        let refused = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(production)
        #expect(refused.status == .blocked && refused.artifactBindings.isEmpty)
        #expect(refused.diagnostics.contains { $0.code.rawValue == "native_production_implementation_unsupported" })
    }

    private func verify(_ result: PhysicalDesignResult, fixture: Fixture, root: URL) async throws
        -> PhysicalDesignPlacementTimingEvidence.Candidate {
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let reloaded = try codec.decode(PhysicalDesignResult.self, from: codec.encode(result))
        let binding = try #require(reloaded.payload.physicalDesign?.layoutArtifact)
        let bytes = try await store.read(binding)
        let snapshot = try codec.decode(PhysicalDesignSnapshot.self, from: bytes)
        try fixture.geometry.validate(snapshot)
        let evidence = try #require(snapshot.implementationState?.placementProof?.timingEvidence)
        try evidence.requireSelectedGeometry(snapshot)
        try PlacementRCProjectionTests().assertNonSelectedGraphRefusal(snapshot)
        #expect(evidence.schemaVersion == 2 && evidence.profileContent == fixture.profile)
        #expect(evidence.originalDesignReference == fixture.request.design.artifact)
        #expect(evidence.selectionDisposition == .setupOptimization)
        #expect(evidence.candidates.count == 2 && snapshot.cells.allSatisfy { $0.master == Self.master })
        #expect(reloaded.payload.claims.production == .blocked && reloaded.payload.claims.timing == .blocked)
        let selected = evidence.candidates[evidence.selectedCandidateIndex]
        let payload = selected.result.payload
        #expect(payload.setupApplicability == .measured)
        #expect(try #require(payload.worstSetupSlack) >= 0)
        try payload.validateSetupApplicabilityStructure()
        let configuration = try #require(payload.effectiveConfiguration)
        #expect(configuration.requireStrictSourceEvidence && configuration.distributedRC == fixture.profile.distributedRC)
        #expect(Set(configuration.analysisKinds) == Set([STAAnalysisKind.setup, .hold, .recovery, .removal, .pulseWidth]))
        #expect(Set(configuration.operatingSupplyAssumptions) == Set(fixture.profile.operatingSupplyAssumptions ?? []))
        #expect(configuration.clockSources.values.allSatisfy { $0.allSatisfy { $0.isPropagated } })
        #expect(!payload.clockObservations.isEmpty && !payload.wireObservations.isEmpty)
        #expect(!payload.wireCoverage.contains { $0.model == .idealClock || $0.model == .uncovered })
        let source = try #require(payload.sourceEvidence)
        #expect(source.roles.allSatisfy { $0.library == fixture.profile.library.reference })
        #expect(!source.pulseWidthSamples.isEmpty && Set(source.pulseWidthSamples.map { $0.observation.openingEdge }) == [.rise, .fall])
        #expect(source.pulseWidthSamples.allSatisfy { $0.slack >= 0 && $0.observation.source.cell == Self.master })
        #expect(source.samples.contains { $0.sequentialCoordinate?.branch == .clock })
        #expect(source.samples.contains { $0.observation.quantity == .constraint })
        #expect(try PhysicalDesignPlacementTimingEvidence.nonSetupRejection(selected.result, profile: fixture.profile) == nil)
        let bindings = try #require(evidence.sourceBindings)
        #expect(bindings.sequentialBindings.count == 2)
        #expect(bindings.terminals.filter { $0.coverage == .sourceOnlySupply }.count == 8)
        #expect(selected.timingDesign.nets.allSatisfy { $0.capacitance == 0 })
        let rc = try #require(selected.rcInput)
        #expect(!rc.bytes.isEmpty && rc.reference.byteCount == UInt64(rc.bytes.count))
        #expect(rc.reference.digest == (try SHA256ContentDigester().digest(data: rc.bytes)))
        for artifact in reloaded.artifactBindings { _ = try await store.read(artifact) }
        var stale = snapshot; stale.pins[0].x += 5
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try evidence.requireSelectedGeometry(stale) }
        return selected
    }

    private struct Fixture {
        let request: PhysicalDesignRequest
        let store: InMemoryPhysicalDesignArtifactStore
        let geometry: PhysicalDesignProcessGeometry
        let profile: PhysicalDesignPlacementTimingProfile
    }

    private func fixture() async throws -> Fixture {
        let sources = try selectedSources()
        let store = InMemoryPhysicalDesignArtifactStore()
        let tech = try await store.registerInput(sources.technology, relativePath: "inputs/selected-original-tech.lef", kind: .technology, format: .lef)
        let cells = try await store.registerInput(sources.cells, relativePath: "inputs/selected-original-cells.lef", kind: .technology, format: .lef)
        let library = try await store.registerInput(sources.library, relativePath: "inputs/selected-original.lib", kind: .technology, format: .liberty)
        let report = try await store.registerInput(sources.report, relativePath: "inputs/source-selection.json", kind: .technology, format: .json)
        let document = try LEFLibraryReader.read(sources.cells)
        let master = try #require(document.macros.first { $0.name == Self.master })
        let terminals = master.pins.enumerated().map { index, pin -> PDKDeviceTerminal in
            let role: PDKTerminalRole
            if pin.use == .power { role = .power }
            else if pin.use == .ground { role = .ground }
            else if pin.use == .clock { role = .clock }
            else if pin.direction == .input { role = .input }
            else { role = .output }
            return .init(name: pin.name, role: role, order: index)
        }
        let layers: [PDKLayerDefinition] = [
            .init(layerID: "li1", name: "li1", number: 1, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "mcon", name: "mcon", number: 2, purpose: .via),
            .init(layerID: "met1", name: "met1", number: 3, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "nwell", name: "nwell", number: 4, purpose: .well),
            .init(layerID: "pwell", name: "pwell", number: 5, purpose: .well)]
        let manifest = PDKManifest(processID: "sky130-selected-source-placement-unqualified", version: "c6d73a35-selected-v1", assets: [
            ("tech", PDKAssetRole.technology, tech), ("cells", .cell, cells), ("liberty", .liberty, library)
        ].map { id, role, value in
            .init(assetID: id, role: role, path: value.path, kind: value.descriptor.kind, format: value.descriptor.format,
                sha256: value.reference.digest.hexadecimalValue, byteCount: Int64(value.reference.byteCount),
                cornerIDs: role == .liberty ? [Self.corner] : [])
        }, layers: layers, devices: [.init(deviceID: Self.master, modelName: Self.master, terminals: terminals)],
            corners: [.init(cornerID: Self.corner, pvt: .init(process: .init(name: "typical", nominal: true), voltage: 1.8, temperatureCelsius: 25),
                rcCorner: "nom", assetIDs: ["tech", "liberty"], viewMappings: ["liberty": "liberty"])],
            crossViewMappings: [.init(mappingID: "tech", view: .lef, assetID: "tech", layerIDs: layers.map(\.layerID)),
                .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: document.macros.map(\.name), layerIDs: layers.map(\.layerID), deviceIDs: [Self.master]),
                .init(mappingID: "timing", view: .liberty, assetID: "liberty", cornerIDs: [Self.corner])])
        try #require(manifest.validate().isValid, "\(manifest.validate().findings)")
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        let mapped = "module top(input c,output q);wire n;\(Self.master) U0(.CLK(c),.D(q),.Q(n));\(Self.master) U1(.CLK(c),.D(n),.Q(q));endmodule"
        let design = try await store.registerInput(Data(mapped.utf8), relativePath: "inputs/mapped.v", kind: .netlist, format: .verilog)
        let sdc = """
        create_clock -name c -period 10ns -waveform {0ns 5ns} [get_ports c]
        set_clock_transition -rise 0.2ns [get_clocks c]
        set_clock_transition -fall 0.2ns [get_clocks c]
        set_propagated_clock [get_clocks c]
        set_output_delay -max 1ns -clock c [get_ports q]
        set_output_delay -min 0ns -clock c [get_ports q]
        """
        let constraints = try await store.registerInput(Data(sdc.utf8), relativePath: "inputs/timing.sdc", kind: .constraint, format: .sdc)
        var supplies: [STAOperatingSupplyAssumption] = []
        for instance in ["U0", "U1"] {
            for (pin, type, value) in [("VPWR", "primary_power", TimingDesign.Constant.one), ("VGND", "primary_ground", .zero),
                                       ("VPB", "nwell", .one), ("VNB", "pwell", .zero)] {
                supplies.append(try .init(instance: instance, cell: Self.master, cornerID: Self.corner,
                    library: library.reference, pin: pin, sourcePGType: type, value: value))
            }
        }
        let rc = try STADistributedRCOptions(maximumTimeStep: 2e-11, stopTime: 2e-7, crossingTolerance: 2e-12,
            maximumRefinements: 10, maximumNodes: 16, maximumSteps: 2_000_000)
        let profile = PhysicalDesignPlacementTimingProfile.sourceBoundSequential(manifest: pdk.reference, library: library,
            libertyAssetID: "liberty", capacitanceAssetID: "tech", cornerID: Self.corner, rcCornerID: "nom", conditionName: Self.corner,
            wireLayer: 1, wireWidthDBU: 170, operatingSupplyAssumptions: supplies, distributedRC: rc)
        let profileBinding = try await store.registerInput(try codec.encode(profile), relativePath: "inputs/profile.json", kind: .technology, format: .json)
        // Reuse the established finite host profile; a real-source failure does not raise these limits.
        let limits = PhysicalDesignPlacementTimingReference(artifact: profileBinding, maximumInputBytes: 2_000_000,
            maximumLiveBytes: 50_000_000, maximumWorkUnits: 200_000_000, maximumPathWorkUnitsPerAnalysis: 5_000_000,
            maximumPathStates: 10_000, maximumEvidenceBytes: 8_000_000, timeoutNanoseconds: 60_000_000_000)
        var snapshot = PhysicalDesignSnapshot(topCell: "top", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 18400, height: 8160), core: .init(x: 0, y: 0, width: 18400, height: 8160),
            rows: [0, 2720, 5440].map { .init(id: "row-\($0)", originX: 0, originY: Int64($0), siteWidth: 460,
                height: 2720, siteCount: 40, siteName: "unithd") },
            cells: [.init(id: "U0", master: Self.master, width: 7360, height: 2720),
                    .init(id: "U1", master: Self.master, width: 7360, height: 2720)])
        snapshot.pins = [.init(id: "c", name: "c", x: 16790, y: 1300, netID: "c", direction: "input", accessLayer: 1,
            topPort: .init(rectangle: .init(x: 0, y: 0, width: 200, height: 200), layer: 1,
                placementX: 16690, placementY: 1200, orientation: .n, placementStatus: .fixed, use: .clock)),
            .init(id: "q", name: "q", x: 17710, y: 4000, netID: "q", direction: "output", accessLayer: 1,
            topPort: .init(rectangle: .init(x: 0, y: 0, width: 200, height: 200), layer: 1,
                placementX: 17610, placementY: 3900, orientation: .n, placementStatus: .fixed, use: .signal))]
        for instance in ["U0", "U1"] {
            for (pin, net, direction) in [("CLK", "c", "input"), ("D", instance == "U0" ? "q" : "n", "input"),
                                          ("Q", instance == "U0" ? "n" : "q", "output")] {
                snapshot.pins.append(.init(id: instance + "/" + pin, cellID: instance, name: pin, netID: net, direction: direction))
            }
        }
        for net in ["c", "n", "q"] {
            snapshot.nets.append(.init(id: net, pinIDs: snapshot.pins.filter { $0.netID == net }.map(\.id),
                isClock: net == "c", defUse: net == "c" ? .clock : .signal))
        }
        var request = PhysicalDesignRequest(runID: "actual-sky130-sequential-placement",
            inputBindings: [pdk, tech, cells, library, report, design, constraints, profileBinding],
            design: .init(artifact: design.reference, topDesignName: "top", designDigest: design.reference.digest.hexadecimalValue), constraints: constraints,
            requestedModeIDs: ["functional"], pdk: try .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk),
                processID: manifest.processID, version: manifest.version), stage: .placement,
            configuration: .init(placementSpacing: 0, preferredRoutingLayers: [1, 3], maximumRoutingLayer: 3,
                implementationConstraints: .init(routeWidth: 170, routeSpacing: 170, sourceRoutingWidthPolicy: .sourceDefault)),
            initialSnapshot: snapshot, executionIntent: .characterizedTiming, placementTimingProfile: limits,
            processAssets: ["tech": tech, "cells": cells])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        let sourceSpacings = try request.configuration.preferredRoutingLayers.map {
            try geometry.routingWidthAndSpacing(layer: $0, units: 1000, width: nil, areaHandledSeparately: true).spacing
        }
        let placementSpacingFloor = try #require(sourceSpacings.max())
        #expect(placementSpacingFloor == 170 && request.configuration.implementationConstraints?.routeSpacing == placementSpacingFloor)
        #expect(geometry.sourceLayers[1]?.resistance == 12.8)
        #expect(geometry.sourceLayers[1]?.capacitance == 36.9866e-6 && geometry.sourceLayers[1]?.edgeCapacitance == 40.697e-6)
        snapshot = try geometry.bind(snapshot)
        for index in snapshot.pins.indices where snapshot.pins[index].cellID != nil {
            let cell = try #require(snapshot.cells.first { $0.id == snapshot.pins[index].cellID })
            snapshot.pins[index] = try geometry.referencePin(snapshot.pins[index], for: cell)
        }
        request.initialSnapshot = snapshot
        return .init(request: request, store: store, geometry: geometry, profile: profile)
    }

    private struct Selection: Codable {
        let schemaVersion: Int
        let scope: String
        let sources: [Source]
    }
    private struct Source: Codable {
        let origin: String
        let originSHA256: String
        let originByteCount: Int
        let selectedFile: String
        let selectedSHA256: String
        let selectedByteCount: Int
        let ranges: [Range]
        let excluded: [Exclusion]
    }
    private struct Range: Codable {
        let startByte: Int
        let endByteExclusive: Int
        let digest: String
        enum CodingKeys: String, CodingKey { case startByte, endByteExclusive; case digest = "SHA256" }
    }
    private struct Exclusion: Codable {
        let fact: String
        let reason: String?
    }
    private struct Sources {
        let technology: Data
        let cells: Data
        let library: Data
        let report: Data
    }

    private func selectedSources() throws -> Sources {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "PhysicalLogicHandoffTests/Fixtures/NativeCTS/Sky130")
        let previous = try codec.decode(Selection.self, from: Data(contentsOf: directory.appending(path: "selection-report.json")))
        var records = previous.sources.filter { $0.selectedFile == "cells.lef" || $0.selectedFile == "timing.lib" }
        try #require(records.count == 2)
        let technology = Source(origin: "/Users/1amageek/.volare/sky130A/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef",
            originSHA256: "5de46c6f7c2cf82599b93d30a6459465f770f63c85b36182c672782219938519", originByteCount: 18167,
            selectedFile: "technology.lef", selectedSHA256: "c211f6f460de59d15c893f7dacdb4b814d748de21cec625b506dfafec12dddcd", selectedByteCount: 2863,
            ranges: [
                .init(startByte: 0, endByteExclusive: 1029, digest: "15736afba1374bd3f8a9e612449032f3e15a9cd7e8672a85b2b7be8f8faedc14"),
                .init(startByte: 1142, endByteExclusive: 1224, digest: "534ab94f0d6435d004c0f1deb4e7f28969bad922beba42a4d066c531cffce1d3"),
                .init(startByte: 1225, endByteExclusive: 1307, digest: "22f1a87ac650ebc36c3cbd9f9356a0e30a778376fa3ca91fdf5e0bd67b90f057"),
                .init(startByte: 1344, endByteExclusive: 1829, digest: "95e88299cdbb36e1422ef863856b064a3db54fa6478b554fce1ca11f2ff66cdc"),
                .init(startByte: 1830, endByteExclusive: 2125, digest: "b395e60f426af87472869719a0000565a0302acf27499aadbf908583126ce069"),
                .init(startByte: 2194, endByteExclusive: 2204, digest: "9ea959528be783e1cce3c15bcbbda82291c907729ba56ac84af5fb1427effb33"),
                .init(startByte: 2205, endByteExclusive: 2777, digest: "512f429a73070edc88cc32f1b32830d1f22b9b6bb6b8182e61853679171210f8"),
                .init(startByte: 2899, endByteExclusive: 3014, digest: "b409ac7ee459278bf9dbb074b4dc69b4728b9278d217d7de7cf9976fabc273a1"),
                .init(startByte: 7534, endByteExclusive: 7715, digest: "7d125296210623ce0b9faaf6431de0b42ce40e054e3199638416b39257d764e1"),
                .init(startByte: 18155, endByteExclusive: 18167, digest: "1b644ce0749ecfcdade8a36b32343c83c8e31e1ae6174d43ac8175b99ac67693")],
            excluded: [.init(fact: "Current-density/EM declarations excluded; no electrical signoff claim.", reason: nil),
                .init(fact: "Other source layers, sites, generated VIA rules and fixed VIA masters excluded.", reason: nil)])
        records.append(technology)
        var selected: [String: Data] = [:]
        for record in records {
            let origin = URL(fileURLWithPath: record.origin)
            let size = try FileManager.default.attributesOfItem(atPath: origin.path)[.size] as? NSNumber
            try #require(size?.intValue == record.originByteCount && record.originByteCount <= 32 * 1_048_576)
            let original = try Data(contentsOf: origin, options: .mappedIfSafe)
            try #require(SHA256ContentDigester().digest(data: original).hexadecimalValue == record.originSHA256)
            var bytes = Data(); bytes.reserveCapacity(record.selectedByteCount)
            for range in record.ranges {
                try #require(range.startByte >= 0 && range.endByteExclusive > range.startByte && range.endByteExclusive <= original.count)
                let part = original[range.startByte..<range.endByteExclusive]
                try #require(SHA256ContentDigester().digest(data: part).hexadecimalValue == range.digest)
                bytes.append(part)
            }
            try #require(bytes.count == record.selectedByteCount)
            try #require(SHA256ContentDigester().digest(data: bytes).hexadecimalValue == record.selectedSHA256)
            if record.selectedFile != "technology.lef" {
                let retained = try Data(contentsOf: directory.appending(path: record.selectedFile))
                try #require(bytes == retained)
            }
            selected[record.selectedFile] = bytes
        }
        let report = Selection(schemaVersion: 1,
            scope: "Actual selected unmodified Sky130 source for pre-route host placement. Omitted whole-source laws and physical supplies are unqualified; no CTS analytical RC or post-route closure is reused.", sources: records)
        return try .init(technology: #require(selected["technology.lef"]), cells: #require(selected["cells.lef"]),
            library: #require(selected["timing.lib"]), report: codec.encode(report))
    }
}
