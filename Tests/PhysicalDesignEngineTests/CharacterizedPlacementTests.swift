import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import LEF
import PDKCore
import PhysicalDesignEngine
import PlacementEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Characterized pre-route placement", .timeLimit(.minutes(1)))
struct CharacterizedPlacementTests {
    @Test("actual source-characterized setup cost reverses placement when the critical endpoint reverses")
    func characterizedChoice() async throws {
        var positions: [Int64] = []
        var wirelengths: [Double] = []
        for reversed in [false, true] {
            let (request, store, geometry) = try await fixture(reversed: reversed)
            let result = try await NativePlacementEngine(artifactStore: store).execute(request)
            #expect(result.status == .completed, "\(result.diagnostics)")
            let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
                from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
            let evidence = try #require(output.implementationState?.placementProof?.timingEvidence)
            #expect(evidence.candidates.count == 2 && evidence.candidateChecks == 5)
            #expect(evidence.structuralCeiling == 50)
            #expect(evidence.selectedCandidateIndex == (reversed ? 0 : 1))
            let baseline = try #require(evidence.candidates[0].result.payload.worstSetupSlack)
            let selected = try #require(evidence.candidates[evidence.selectedCandidateIndex].result.payload.worstSetupSlack)
            #expect(reversed ? selected == baseline : selected > baseline)
            try geometry.validate(output)
            try evidence.requireSelectedGeometry(output)
            let reloaded = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: PhysicalDesignJSONCodec().encode(output))
            #expect(reloaded == output && reloaded.validationDiagnostics().isEmpty)
            var stale = output; stale.cells[0].x += 460
            #expect(throws: PhysicalDesignPlacementTimingError.self) { try evidence.requireSelectedGeometry(stale) }
            #expect(!stale.validationDiagnostics().isEmpty)
            #expect(result.payload.claims.geometry == .verified && result.payload.claims.timing == .blocked && result.payload.claims.production == .blocked)
            positions.append(try #require(output.cells.first { $0.id == "U1" }).x)
            wirelengths.append(try #require(output.implementationState?.placementProof?.wirelengthObjectiveDBU))
            let manifestBinding = try #require(result.artifactBindings.first { $0.path.hasSuffix("manifest.json") })
            let manifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self, from: await store.read(manifestBinding))
            #expect(manifest.placementTimingProfile == request.placementTimingProfile)
            if !reversed {
                var resumed = request
                resumed.runID += "-resume"
                resumed.initialSnapshot = nil
                let physical = try #require(result.payload.physicalDesign)
                resumed.inputLayout = physical
                resumed.inputBindings.append(physical.layoutArtifact); resumed.inputs.append(physical.layoutArtifact.reference)
                let replay = try await NativePlacementEngine(artifactStore: store).execute(resumed)
                #expect(replay.status == .completed, "\(replay.diagnostics)")
                let loaded = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
                    from: await store.read(try #require(replay.payload.physicalDesign?.layoutArtifact)))
                #expect(loaded.cells == output.cells && loaded.pins == output.pins)
                #expect(loaded.implementationState?.placementProof?.timingEvidence?.profile == evidence.profile)
                try #require(loaded.implementationState?.placementProof?.timingEvidence).requireSelectedGeometry(loaded)
                var exhausted = request
                let limits = try #require(request.placementTimingProfile)
                exhausted.placementTimingProfile = .init(artifact: limits.artifact, maximumInputBytes: limits.maximumInputBytes,
                    maximumLiveBytes: limits.maximumLiveBytes, maximumWorkUnits: evidence.chargedWorkUnits - limits.maximumPathWorkUnitsPerAnalysis,
                    maximumPathWorkUnitsPerAnalysis: limits.maximumPathWorkUnitsPerAnalysis, maximumPathStates: limits.maximumPathStates,
                    maximumEvidenceBytes: limits.maximumEvidenceBytes, timeoutNanoseconds: limits.timeoutNanoseconds)
                let blocked = try await NativePlacementEngine(artifactStore: store).execute(exhausted)
                #expect(blocked.status == .blocked && blocked.artifactBindings.isEmpty)
                #expect(blocked.diagnostics.contains { $0.code.rawValue == "placement_timing_resource_limit" })
            }
            print("placement reversed=\(reversed) selected=\(evidence.selectedCandidateIndex) baseline=\(baseline) selectedSlack=\(selected) checks=\(evidence.candidateChecks) work=\(evidence.chargedWorkUnits)")
        }
        #expect(positions == [1380, 0])
        #expect(wirelengths[0] == wirelengths[1])
    }

    @Test("missing, stale, unavailable and exhausted characterization never publishes a candidate", arguments: ["missing", "corner", "graph", "work", "candidate", "input", "live", "evidence", "deadline", "range", "minimum", "condition", "production"])
    func refusal(_ reason: String) async throws {
        var (request, store, _) = try await fixture()
        let reference = try #require(request.placementTimingProfile)
        switch reason {
        case "missing": request.placementTimingProfile = nil
        case "graph":
            request.initialSnapshot?.cells[0].id = "forged"
            for index in request.initialSnapshot!.pins.indices where request.initialSnapshot!.pins[index].cellID == "U1" {
                request.initialSnapshot?.pins[index].cellID = "forged"
            }
            #expect(request.initialSnapshot?.validationDiagnostics().isEmpty == true)
        case "candidate": request.configuration.maximumPlacementCandidateChecks = 4
        case "production": request.executionIntent = .productionImplementation
        case "range":
            let changed = try await store.registerInput(Data(Self.constraints(reversed: false).replacingOccurrences(of: "0.1 [all_inputs]", with: "100 [all_inputs]").utf8), relativePath: "inputs/range.sdc", kind: .constraint, format: .sdc)
            request.constraints = changed; request.inputBindings.append(changed); request.inputs.append(changed.reference)
        case "corner", "minimum", "condition":
            let old = try PhysicalDesignJSONCodec().decode(PhysicalDesignPlacementTimingProfile.self, from: await store.read(reference.artifact))
            let changed = PhysicalDesignPlacementTimingProfile(manifest: old.manifest, library: old.library, libertyAssetID: old.libertyAssetID,
                capacitanceAssetID: old.capacitanceAssetID, cornerID: reason == "corner" ? "unknown" : old.cornerID,
                rcCornerID: old.rcCornerID, conditionName: reason == "condition" ? "unknown" : old.conditionName,
                wireLayer: old.wireLayer, wireWidthDBU: old.wireWidthDBU, minimumSetupSlackSeconds: reason == "minimum" ? 1 : nil)
            let binding = try await store.registerInput(try PhysicalDesignJSONCodec().encode(changed), relativePath: "inputs/changed-profile.json", kind: .technology, format: .json)
            request.inputBindings.append(binding); request.inputs.append(binding.reference)
            request.placementTimingProfile = limits(reference, artifact: binding)
        default: request.placementTimingProfile = limits(reference, reason: reason)
        }
        let result = try await NativePlacementEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
        #expect(result.payload.physicalDesign == nil)
        let expected: String
        switch reason {
        case "missing": expected = "placement_timing_profile_required"
        case "corner": expected = "placement_timing_profile_invalid"
        case "graph": expected = "placement_timing_graph_mismatch"
        case "candidate": expected = "placement_candidate_budget_exceeded"
        case "deadline": expected = "placement_timing_deadline"
        case "range", "minimum", "condition": expected = "placement_timing_unavailable"
        case "production": expected = "native_production_implementation_unsupported"
        default: expected = "placement_timing_resource_limit"
        }
        #expect(result.diagnostics.contains { $0.code.rawValue == expected }, "\(result.diagnostics)")
    }

    @Test("pre-cancelled characterized placement retains no output")
    func cancellation() async throws {
        let (request, store, _) = try await fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativePlacementEngine(artifactStore: store).execute(request)
        }
        let result = try await task.value
        #expect(result.status == .cancelled && result.artifactBindings.isEmpty)
    }

    @Test("unmodified source blocks retain exact selected macro and technology facts while original full source refuses")
    func sourceSelection() async throws {
        let (request, store, geometry) = try await fixture()
        let master = try geometry.requireMaster(Self.master)
        #expect(master.width == 1380 && master.height == 2720)
        #expect(Set(master.pins.keys) == ["A", "Y", "VGND", "VPWR", "VNB", "VPB"])
        #expect(master.pins["Y"]?.shapes.count == 3 && master.obstructions.count == 4)
        #expect(geometry.sites["unithd"]?.width == 460 && geometry.sites["unithd"]?.height == 2720)
        #expect(geometry.sourceLayers[1]?.capacitance == 36.9866e-6)
        let report = try JSONSerialization.jsonObject(with: source("selection-report.json")) as! [String: Any]
        for entry in report["sources"] as! [[String: Any]] {
            let selected = try source(entry["selectedFile"] as! String)
            #expect(try SHA256ContentDigester().digest(data: selected, using: .sha256).hexadecimalValue == entry["selectedSHA256"] as? String)
            let origin = URL(fileURLWithPath: entry["origin"] as! String)
            if FileManager.default.fileExists(atPath: origin.path) {
                let original = try Data(contentsOf: origin)
                #expect(try SHA256ContentDigester().digest(data: original, using: .sha256).hexadecimalValue == entry["originSHA256"] as? String)
                var joined = Data()
                for range in entry["ranges"] as! [[String: Int]] { joined.append(original[range["startByte"]!..<range["endByteExclusive"]!]) }
                #expect(joined == selected)
            }
        }
        var originalRequest = request
        let binding = try await store.registerInput(source("original-technology.raw"), relativePath: "inputs/original-tech.lef", kind: .technology, format: .lef)
        var manifest = try PDKManifestCodec.decode(data: await store.read(request.requireBinding(for: request.pdk.manifest)))
        let index = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[index].sha256 = binding.reference.digest.hexadecimalValue; manifest.assets[index].byteCount = Int64(binding.reference.byteCount)
        let originalManifest = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/original-process.json", kind: .technology, format: .json)
        originalRequest.processAssets["tech"] = binding
        originalRequest.inputBindings.removeAll { $0 == request.processAssets["tech"] }
        originalRequest.inputBindings += [binding, originalManifest]; originalRequest.inputs += [binding.reference, originalManifest.reference]
        originalRequest.pdk = try .init(manifest: originalManifest.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: originalManifest), processID: manifest.processID, version: manifest.version)
        let result = try await NativePlacementEngine(artifactStore: store).execute(originalRequest)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty)
    }

    @Test("built CLI retains the identical selected characterized candidate and explicit estimated scope")
    func cli() async throws {
        let (request, memory, geometry) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: "characterized-placement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("CLI cleanup: \(error)") } }
        for binding in request.inputBindings {
            let destination = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: destination)
        }
        let requestURL = root.appending(path: "request.json"), outputURL = root.appending(path: "result.json")
        try PhysicalDesignJSONCodec().encode(request).write(to: requestURL)
        #expect(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { do { try handle.close() } catch { Issue.record("CLI output close: \(error)") } }
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", requestURL.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        process.waitUntilExit()
        let result = try PhysicalDesignJSONCodec().decode(PhysicalDesignResult.self, from: Data(contentsOf: outputURL))
        #expect(process.terminationStatus == 0 && result.status == .completed, "\(result.diagnostics)")
        #expect(result.provenance.producer.version == NativePhysicalDesignExecutor.currentImplementationVersion)
        print("placement CLI producer=\(result.provenance.producer.version)")
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
            from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        let evidence = try #require(output.implementationState?.placementProof?.timingEvidence)
        try evidence.requireSelectedGeometry(output)
        try geometry.validate(output)
        #expect(evidence.selectedCandidateIndex == 1 && output.cells[0].x == 1380)
        #expect(evidence.scope.contains("noPhysicalSignoff"))
        #expect(try #require(evidence.candidates[1].result.payload.worstSetupSlack) > #require(evidence.candidates[0].result.payload.worstSetupSlack))
        for binding in result.artifactBindings { _ = try await store.read(binding) }
    }

    func fixture(reversed: Bool = false) async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore, PhysicalDesignProcessGeometry) {
        let store = InMemoryPhysicalDesignArtifactStore()
        let tech = try await store.registerInput(source("technology.lef"), relativePath: "inputs/selected-tech.lef", kind: .technology, format: .lef)
        let cell = try await store.registerInput(source("cells.lef"), relativePath: "inputs/selected-cells.lef", kind: .technology, format: .lef)
        let liberty = try await store.registerInput(source("timing.lib"), relativePath: "inputs/selected-timing.lib", kind: .technology, format: .liberty)
        let report = try await store.registerInput(source("selection-report.json"), relativePath: "inputs/selection-report.json", kind: .technology, format: .json)
        let raw = try await store.registerInput(source("original-technology.raw"), relativePath: "inputs/original-technology.raw", kind: .technology, format: .raw)
        let layers: [PDKLayerDefinition] = [.init(layerID: "li1", name: "li1", number: 1, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "met1", name: "met1", number: 2, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "nwell", name: "nwell", number: 3, purpose: .well), .init(layerID: "pwell", name: "pwell", number: 4, purpose: .well)]
        let sourceMacro = try #require(LEFLibraryReader.read(source("cells.lef")).macros.first { $0.name == Self.master })
        let terminals = try sourceMacro.pins.enumerated().map { index, pin -> PDKDeviceTerminal in
            let role: PDKTerminalRole
            if pin.use == .power { role = .power }
            else if pin.use == .ground { role = .ground }
            else if pin.direction == .input { role = .input }
            else if pin.direction == .output { role = .output }
            else { throw PhysicalDesignPlacementTimingError.invalidProfile("Unknown actual source terminal role") }
            return .init(name: pin.name, role: role, order: index)
        }
        let manifest = PDKManifest(processID: "sky130A-selected-placement-cost", version: "source-projection-v1", assets: [
            .init(assetID: "tech", role: .technology, path: tech.path, kind: .technology, format: .lef, sha256: tech.reference.digest.hexadecimalValue, byteCount: Int64(tech.reference.byteCount)),
            .init(assetID: "cells", role: .cell, path: cell.path, kind: .technology, format: .lef, sha256: cell.reference.digest.hexadecimalValue, byteCount: Int64(cell.reference.byteCount)),
            .init(assetID: "liberty", role: .liberty, path: liberty.path, kind: .technology, format: .liberty, sha256: liberty.reference.digest.hexadecimalValue, byteCount: Int64(liberty.reference.byteCount), cornerIDs: ["tt"])],
            layers: layers, devices: [.init(deviceID: Self.master, modelName: Self.master, terminals: terminals)], corners: [.init(cornerID: "tt", pvt: .init(process: .init(name: "typical", nominal: true), voltage: 1.8, temperatureCelsius: 25), rcCorner: "nom", assetIDs: ["tech", "liberty"], viewMappings: ["liberty": "liberty"])],
            crossViewMappings: [.init(mappingID: "tech", view: .lef, assetID: "tech", layerIDs: layers.map(\.layerID)),
                .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: [Self.master], layerIDs: layers.map(\.layerID), deviceIDs: [Self.master]),
                .init(mappingID: "timing", view: .liberty, assetID: "liberty", cornerIDs: ["tt"])])
        let validation = manifest.validate()
        try #require(validation.isValid, "\(validation.findings)")
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        let design = try await store.registerInput(Data("module placement_top(input a, input b, output y1, output y2); \(Self.master) U1(.A(a),.Y(y1)); \(Self.master) U2(.A(b),.Y(y2)); endmodule".utf8), relativePath: "inputs/mapped.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data(Self.constraints(reversed: reversed).utf8), relativePath: "inputs/timing.sdc", kind: .constraint, format: .sdc)
        let profile = PhysicalDesignPlacementTimingProfile(manifest: pdk.reference, library: liberty, libertyAssetID: "liberty", capacitanceAssetID: "tech", cornerID: "tt", rcCornerID: "nom", conditionName: "tt_025C_1v80", wireLayer: 1, wireWidthDBU: 170)
        let binding = try await store.registerInput(try PhysicalDesignJSONCodec().encode(profile), relativePath: "inputs/profile.json", kind: .technology, format: .json)
        let reference = PhysicalDesignPlacementTimingReference(artifact: binding, maximumInputBytes: 2_000_000, maximumLiveBytes: 20_000_000,
            maximumWorkUnits: 100_000_000, maximumPathWorkUnitsPerAnalysis: 100_000, maximumPathStates: 1000, maximumEvidenceBytes: 2_000_000, timeoutNanoseconds: 20_000_000_000)
        var snapshot = PhysicalDesignSnapshot(topCell: "placement_top", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 46000, height: 2720), core: .init(x: 0, y: 0, width: 46000, height: 2720),
            rows: [.init(id: "row", originX: 0, originY: 0, siteWidth: 460, height: 2720, siteCount: 100, siteName: "unithd")],
            cells: ["U1", "U2"].map { .init(id: $0, master: Self.master, x: 0, y: 0, width: 1380, height: 2720) },
            pins: [], nets: [])
        for (port, cellID, pin, direction) in [("a", "U1", "A", "input"), ("b", "U2", "A", "input"), ("y1", "U1", "Y", "output"), ("y2", "U2", "Y", "output")] {
            let x: Int64 = direction == "input" ? 100 : 45100
            snapshot.pins.append(.init(id: port, name: port, x: x, y: 1300, netID: port, direction: direction, accessLayer: 1,
                topPort: .init(rectangle: .init(x: 0, y: 0, width: 200, height: 200), layer: 1, placementX: x - 100,
                    placementY: 1200, orientation: .n, placementStatus: .fixed, use: .signal)))
            snapshot.pins.append(.init(id: cellID + "/" + pin, cellID: cellID, name: pin, netID: port, direction: direction))
            snapshot.nets.append(.init(id: port, pinIDs: [port, cellID + "/" + pin]))
        }
        let request = PhysicalDesignRequest(runID: "sky130-placement-\(reversed)", inputBindings: [pdk, liberty, report, raw, design, constraints],
            design: .init(artifact: design.reference, topDesignName: "placement_top", designDigest: design.reference.digest.hexadecimalValue), constraints: constraints,
            requestedModeIDs: ["functional"], pdk: try .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk), processID: manifest.processID, version: manifest.version),
            stage: .placement, configuration: .init(placementSpacing: 0, preferredRoutingLayers: [1, 2], maximumRoutingLayer: 2, implementationConstraints: .init(routeWidth: 170, routeSpacing: 170)), initialSnapshot: snapshot,
            executionIntent: .characterizedTiming, placementTimingProfile: reference, processAssets: ["tech": tech, "cells": cell])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        snapshot = try geometry.bind(snapshot)
        for index in snapshot.pins.indices {
            if let cellID = snapshot.pins[index].cellID {
                let cell = try #require(snapshot.cells.first { $0.id == cellID })
                snapshot.pins[index] = try geometry.referencePin(snapshot.pins[index], for: cell)
            }
        }
        var final = request; final.initialSnapshot = snapshot
        return (final, store, geometry)
    }
    private func source(_ name: String) throws -> Data {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: root.appending(path: "CharacterizedPlacement/Sky130/" + name))
    }
    private static let master = "sky130_fd_sc_hd__inv_1"
    private static func constraints(reversed: Bool) -> String {
        """
        create_clock -name clk -period 10 [get_ports a]
        set_input_delay -clock clk 0 [get_ports a]
        set_input_delay -clock clk 0 [get_ports b]
        set_input_transition 0.1 [all_inputs]
        set_output_delay -clock clk \(reversed ? 0 : 9) [get_ports y1]
        set_output_delay -clock clk \(reversed ? 9 : 0) [get_ports y2]
        """
    }
    private func limits(_ old: PhysicalDesignPlacementTimingReference, artifact: PhysicalDesignArtifactBinding? = nil, reason: String = "") -> PhysicalDesignPlacementTimingReference {
        .init(artifact: artifact ?? old.artifact, maximumInputBytes: reason == "input" ? 1 : old.maximumInputBytes,
            maximumLiveBytes: reason == "live" ? 1 : old.maximumLiveBytes,
            maximumWorkUnits: reason == "work" ? 150_000 : old.maximumWorkUnits,
            maximumPathWorkUnitsPerAnalysis: old.maximumPathWorkUnitsPerAnalysis, maximumPathStates: old.maximumPathStates,
            maximumEvidenceBytes: reason == "evidence" ? 1 : old.maximumEvidenceBytes, timeoutNanoseconds: reason == "deadline" ? 1 : old.timeoutNanoseconds)
    }
}
