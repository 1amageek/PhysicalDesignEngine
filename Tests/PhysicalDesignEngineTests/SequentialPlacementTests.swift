import CircuiteFoundation
import Foundation
import LEF
import PDKCore
import PhysicalDesignEngine
import STAEngine
import Testing
import TimingCore
@testable import PhysicalDesignCore

/// Synthetic source-bound pre-route regression; no process or post-route qualification.
@Suite("Source sequential placement API and CLI", .serialized, .timeLimit(.minutes(3)))
struct SequentialPlacementTests {
    private let codec = PhysicalDesignJSONCodec()

    @Test("Source checks and applicability survive filesystem API and CLI", arguments: ["ff", "latch", "ff-no-pulse", "ff-reset"])
    func persistedAPIAndCLI(_ kind: String) async throws {
        let fixture = try await fixture(kind: kind)
        let retained = ProcessInfo.processInfo.environment["LSI_PHYSICAL_S3_EVIDENCE_ROOT"]
        let root = retained.map { URL(fileURLWithPath: $0).appending(path: "synthetic-sequential-placement-" + kind) }
            ?? FileManager.default.temporaryDirectory.appending(path: "sequential-placement-\(kind)-\(UUID().uuidString)")
        try #require(!FileManager.default.fileExists(atPath: root.path))
        defer {
            if retained == nil { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        }
        let apiRoot = root.appending(path: "api"), cliRoot = root.appending(path: "cli")
        for directory in [apiRoot, cliRoot] {
            for binding in fixture.request.inputBindings {
                let target = directory.appending(path: binding.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await fixture.store.read(binding).write(to: target)
            }
            try codec.encode(fixture.request).write(to: directory.appending(path: "request.json"))
        }
        let api = try await PhysicalDesignEngine(artifactStore: FileSystemPhysicalDesignArtifactStore(projectRoot: apiRoot)).execute(fixture.request)
        try codec.encode(api).write(to: apiRoot.appending(path: "api-result.json"))
        #expect(api.status == .completed, "\(api.diagnostics)")
        guard api.status == .completed else { #expect(api.artifactBindings.isEmpty); return }
        let reloadedAPI = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: apiRoot.appending(path: "api-result.json")))
        let first = try await verify(reloadedAPI, fixture: fixture, root: apiRoot, kind: kind)

        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", cliRoot.appending(path: "request.json").path, "--project-root", cliRoot.path]
        let resultURL = cliRoot.appending(path: "cli-result.json")
        try Data().write(to: resultURL)
        let output = try FileHandle(forWritingTo: resultURL)
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
        let cli = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: resultURL))
        #expect(process.terminationStatus == 0 && cli.status == .completed, "\(cli.diagnostics)")
        guard cli.status == .completed else { #expect(cli.artifactBindings.isEmpty); return }
        let second = try await verify(cli, fixture: fixture, root: cliRoot, kind: kind)
        #expect(first.snapshotDigest == second.snapshotDigest)
        #expect(first.timingDesignReference == second.timingDesignReference)
        #expect(first.rcInput == second.rcInput)
        #expect(first.result.payload.sourceEvidence == second.result.payload.sourceEvidence)
        #expect(first.result.payload.worstSetupSlack == second.result.payload.worstSetupSlack)
    }

    @Test("Unknown checks, absent supply conditions and stale source references cannot publish", arguments: ["missing-input", "missing-hold", "missing-supply", "stale-corner", "ideal-clock", "dynamic-reset", "static-minimum"])
    func refusal(_ reason: String) async throws {
        let fixture = try await fixture(kind: reason == "static-minimum" ? "ff-reset" : "ff", refusal: reason)
        let result = try await PhysicalDesignEngine(artifactStore: fixture.store).execute(fixture.request)
        #expect(result.status == .blocked, "\(result.diagnostics)")
        #expect(result.payload.physicalDesign == nil && result.artifactBindings.isEmpty)
        #expect(result.diagnostics.contains { $0.code.rawValue.hasPrefix("placement_timing_") })
    }

    private func verify(_ result: PhysicalDesignResult, fixture: Fixture, root: URL,
                        kind: String) async throws -> PhysicalDesignPlacementTimingEvidence.Candidate {
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let snapshot = try codec.decode(PhysicalDesignSnapshot.self,
            from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        try fixture.geometry.validate(snapshot)
        let evidence = try #require(snapshot.implementationState?.placementProof?.timingEvidence)
        try evidence.requireSelectedGeometry(snapshot)
        if kind != "ff-reset" { try PlacementRCProjectionTests().assertNonSelectedGraphRefusal(snapshot) }
        if kind == "ff" { try PlacementRCProjectionTests().assertSetupApplicabilityForgeryRefusal(snapshot) }
        #expect(evidence.schemaVersion == 2 && evidence.model == "lefDistributedRCStarV2")
        #expect(evidence.profileContent == fixture.profile && evidence.originalDesignReference == fixture.request.design.artifact)
        #expect(result.payload.claims.timing == .blocked && result.payload.claims.production == .blocked)
        let bindings = try #require(evidence.sourceBindings)
        #expect(bindings.sequentialBindings.count == 1)
        #expect(bindings.terminals.filter { $0.coverage == .sourceOnlySupply }.count == 2)
        #expect(bindings.terminals.contains { $0.pinName == "VPWR" && $0.role == .power && $0.netID == nil })
        let selected = evidence.candidates[evidence.selectedCandidateIndex]
        #expect(selected.accepted && selected.result.status == .completed)
        if kind == "ff-reset" {
            #expect(evidence.selectionDisposition == .baselinePreservedNoApplicableSetup)
            #expect(selected.result.payload.setupApplicability == .sourceNotApplicable)
            #expect(selected.result.payload.worstSetupSlack == nil)
            #expect(selected.result.payload.endpoints.allSatisfy { $0.setupSlack == nil })
            #expect(evidence.candidates.count == 1 && evidence.selectedCandidateIndex == 0)
            #expect(selected.swappedCellIDs.isEmpty)
            #expect(snapshot.metadata["placementTimingSelectionDisposition"] == "baselinePreservedNoApplicableSetup")
            #expect(!result.payload.metrics.contains { $0.name == "placementInitialSetupSlack" || $0.name == "placementSelectedSetupSlack" })
        } else {
            #expect(evidence.selectionDisposition == .setupOptimization)
            #expect(selected.result.payload.setupApplicability == .measured)
            #expect(try #require(selected.result.payload.worstSetupSlack) >= 0)
        }
        #expect(selected.timingDesign.nets.allSatisfy { $0.capacitance == 0 })
        let rc = try #require(selected.rcInput)
        #expect(!rc.bytes.isEmpty && rc.reference.byteCount == UInt64(rc.bytes.count))
        let spef = try SPEFParser().parse(rc.bytes)
        #expect(spef.network(named: "clk")?.connections.contains { $0.name == "U:C" } == true)
        #expect(spef.network(named: "d")?.connections.contains { $0.name == "U:D" } == true)
        let payload = selected.result.payload
        let configuration = try #require(payload.effectiveConfiguration)
        #expect(configuration.requireStrictSourceEvidence && configuration.distributedRC == fixture.profile.distributedRC)
        #expect(configuration.clockSources.values.allSatisfy { $0.allSatisfy { $0.isPropagated } })
        #expect(!payload.clockObservations.isEmpty && !payload.wireObservations.isEmpty)
        #expect(!payload.wireCoverage.contains { $0.model == .idealClock || $0.model == .uncovered })
        let source = try #require(payload.sourceEvidence)
        if kind == "ff-no-pulse" {
            #expect(source.pulseWidthSamples.isEmpty)
            let pulseRoles = source.roles.filter { $0.analysisKind == .pulseWidth }
            #expect(!pulseRoles.isEmpty)
            #expect(pulseRoles.allSatisfy { source.checkStatus(for: $0) == .sourceNotApplicable })
            #expect(payload.endpoints.allSatisfy { $0.pulseWidthSlack == nil })
        } else {
            #expect(source.pulseWidthSamples.count == 4)
            #expect(Set(source.pulseWidthSamples.map { $0.observation.openingEdge }) == [.rise, .fall])
            #expect(source.pulseWidthSamples.allSatisfy { $0.minimumWidth == 0.5e-9 && $0.slack >= 0 })
            #expect(source.pulseWidthSamples.allSatisfy { $0.observation.source.cell == "STATE" && $0.observation.source.pin == "C" })
            for pulse in source.pulseWidthSamples {
                #expect(pulse.observation.inputSlew == pulse.openingSlew)
                #expect(pulse.observation.minimumSlew == 0 && pulse.observation.maximumSlew == 20e-9)
                #expect(pulse.observation.table.name == (pulse.observation.openingEdge == .rise ? "rise_constraint" : "fall_constraint"))
                #expect(pulse.observation.source.tables.contains(pulse.observation.table))
            }
        }
        if kind != "ff-reset" { #expect(source.samples.contains { $0.observation.quantity == .constraint }) }
        if kind == "latch" {
            #expect(source.samples.contains { $0.sequentialCoordinate?.branch == .data })
            #expect(source.samples.contains { $0.observation.quantity == .constraint && $0.observation.result < 0 })
        } else if kind == "ff-reset" {
            #expect(source.staticStateSamples.contains { $0.effect == .clear && $0.outputConstants["Q"] == .zero })
            let output = try #require(payload.endpoints.first { $0.endpoint == "q" })
            #expect(output.staticValue == .zero && output.setupSlack == nil)
            #expect(bindings.constants.contains { $0.netID == "rn" && $0.kind == .sourceTieOutput && $0.value == .zero })
            let setupRoles = source.roles.filter { $0.analysisKind == .setup }
            #expect(!setupRoles.isEmpty)
            #expect(setupRoles.allSatisfy { source.checkStatus(for: $0) == .staticStateNotApplicable || source.checkStatus(for: $0) == .sourceNotApplicable })
        } else {
            #expect(source.samples.contains { $0.sequentialCoordinate?.branch == .clock })
            #expect(source.staticStateSamples.contains { $0.effect == .inactive })
            let controls = source.roles.filter { $0.checkKind == .recovery || $0.checkKind == .removal }
            #expect(!controls.isEmpty && controls.allSatisfy { source.checkStatus(for: $0) == .staticControlNotApplicable })
            #expect(bindings.constants.contains { $0.netID == "rn" && $0.kind == .sourceTieOutput && $0.value == .one })
        }
        for binding in result.artifactBindings { _ = try await store.read(binding) }
        var stale = snapshot; stale.pins[0].x += 100
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try evidence.requireSelectedGeometry(stale) }
        var json = try #require(JSONSerialization.jsonObject(with: codec.encode(snapshot)) as? [String: Any])
        var state = try #require(json["implementationState"] as? [String: Any])
        var proof = try #require(state["placementProof"] as? [String: Any])
        var timing = try #require(proof["timingEvidence"] as? [String: Any])
        timing["sourceBindings"] = NSNull()
        proof["timingEvidence"] = timing; state["placementProof"] = proof; json["implementationState"] = state
        let unknown = try codec.decode(PhysicalDesignSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        let missing = try #require(unknown.implementationState?.placementProof?.timingEvidence)
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try missing.requireSelectedGeometry(unknown) }
        return selected
    }

    private struct Fixture {
        let request: PhysicalDesignRequest
        let store: InMemoryPhysicalDesignArtifactStore
        let geometry: PhysicalDesignProcessGeometry
        let profile: PhysicalDesignPlacementTimingProfile
    }

    private func fixture(kind: String, refusal: String = "") async throws -> Fixture {
        let stateKind = kind == "latch" ? "latch" : "ff"
        let tiedReset = stateKind == "ff" && refusal != "dynamic-reset"
        let store = InMemoryPhysicalDesignArtifactStore()
        let tech = try await store.registerInput(Data(Self.technology.utf8), relativePath: "inputs/tech.lef", kind: .technology, format: .lef)
        let cells = try await store.registerInput(Data(cellLEF(stateKind, tiedReset: tiedReset).utf8), relativePath: "inputs/cells.lef", kind: .technology, format: .lef)
        let library = try await store.registerInput(Data(liberty(stateKind, missingHold: refusal == "missing-hold", pulse: kind != "ff-no-pulse", tie: tiedReset ? (kind == "ff-reset" ? "0" : "1") : nil).utf8), relativePath: "inputs/timing.lib", kind: .technology, format: .liberty)
        let terminals = try #require(LEFLibraryReader.read(Data(cellLEF(stateKind, tiedReset: tiedReset).utf8)).macros.first).pins.enumerated().map { index, pin -> PDKDeviceTerminal in
            let role: PDKTerminalRole
            if pin.use == .power { role = .power }
            else if pin.use == .ground { role = .ground }
            else if pin.direction == .input { role = .input }
            else { role = .output }
            return .init(name: pin.name, role: role, order: index)
        }
        let layer = PDKLayerDefinition(layerID: "M1", name: "m1", number: 1, purpose: .metal, isRoutingLayer: true)
        let manifest = PDKManifest(processID: "synthetic-sequential-placement", version: "1", assets: [
            .init(assetID: "tech", role: .technology, path: tech.path, kind: .technology, format: .lef, sha256: tech.reference.digest.hexadecimalValue, byteCount: Int64(tech.reference.byteCount)),
            .init(assetID: "cells", role: .cell, path: cells.path, kind: .technology, format: .lef, sha256: cells.reference.digest.hexadecimalValue, byteCount: Int64(cells.reference.byteCount)),
            .init(assetID: "liberty", role: .liberty, path: library.path, kind: .technology, format: .liberty, sha256: library.reference.digest.hexadecimalValue, byteCount: Int64(library.reference.byteCount), cornerIDs: ["tt"])],
            layers: [layer], devices: [.init(deviceID: "STATE", modelName: "STATE", terminals: terminals)]
                + (tiedReset ? [.init(deviceID: "TIE", modelName: "TIE", terminals: [.init(name: "Y", role: .output, order: 0)])] : []),
            corners: [.init(cornerID: "tt", pvt: .init(process: .init(name: "typical", nominal: true), voltage: 1, temperatureCelsius: 25), rcCorner: "nom", assetIDs: ["tech", "liberty"], viewMappings: ["liberty": "liberty"])],
            crossViewMappings: [.init(mappingID: "tech", view: .lef, assetID: "tech", layerIDs: ["M1"]),
                .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: tiedReset ? ["STATE", "TIE"] : ["STATE"], layerIDs: ["M1"], deviceIDs: tiedReset ? ["STATE", "TIE"] : ["STATE"]),
                .init(mappingID: "timing", view: .liberty, assetID: "liberty", cornerIDs: ["tt"])])
        try #require(manifest.validate().isValid)
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        let ports = stateKind == "ff" ? [("clk", "C", "input"), ("d", "D", "input"), ("rn", "RN", "input"), ("q", "Q", "output")]
            : [("clk", "C", "input"), ("d", "D", "input"), ("q", "Q", "output")]
        let source = "module top(input clk, input d, " + (stateKind == "ff" && !tiedReset ? "input rn, " : "")
            + "output q); " + (tiedReset ? "wire rn; TIE T(.Y(rn)); " : "")
            + "STATE U(.C(clk),.D(d)," + (stateKind == "ff" ? ".RN(rn)," : "") + ".Q(q)); endmodule"
        let design = try await store.registerInput(Data(source.utf8), relativePath: "inputs/mapped.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data(sdc(stateKind, refusal: refusal, tiedReset: tiedReset).utf8), relativePath: "inputs/timing.sdc", kind: .constraint, format: .sdc)
        let supplies = try [("VPWR", "primary_power", TimingDesign.Constant.one), ("VGND", "primary_ground", .zero)].map {
            try STAOperatingSupplyAssumption(instance: "U", cell: "STATE", cornerID: "tt", library: library.reference, pin: $0.0, sourcePGType: $0.1, value: $0.2)
        }
        let rc = try STADistributedRCOptions(maximumTimeStep: 2e-11, stopTime: 2e-7, crossingTolerance: 2e-12,
            maximumRefinements: 10, maximumNodes: 16, maximumSteps: 2_000_000)
        let profile = PhysicalDesignPlacementTimingProfile.sourceBoundSequential(manifest: pdk.reference, library: library,
            libertyAssetID: "liberty", capacitanceAssetID: "tech", cornerID: refusal == "stale-corner" ? "unknown" : "tt", rcCornerID: "nom", conditionName: "tt",
            wireLayer: 1, wireWidthDBU: 100, operatingSupplyAssumptions: refusal == "missing-supply" ? [] : supplies,
            distributedRC: rc, minimumSetupSlackSeconds: refusal == "static-minimum" ? 0 : nil)
        let binding = try await store.registerInput(try codec.encode(profile), relativePath: "inputs/profile.json", kind: .technology, format: .json)
        // Finite test-owned operating limits include both actual STA and retained-source replay.
        let reference = PhysicalDesignPlacementTimingReference(artifact: binding, maximumInputBytes: 2_000_000,
            maximumLiveBytes: 50_000_000, maximumWorkUnits: 200_000_000, maximumPathWorkUnitsPerAnalysis: 5_000_000,
            maximumPathStates: 10_000, maximumEvidenceBytes: 8_000_000, timeoutNanoseconds: 60_000_000_000)
        var snapshot = PhysicalDesignSnapshot(topCell: "top", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 4000, height: 1000), core: .init(x: 0, y: 0, width: 4000, height: 1000),
            rows: [.init(id: "row", originX: 0, originY: 0, siteWidth: 100, height: 1000, siteCount: 40, siteName: "unit")],
            cells: [.init(id: "U", master: "STATE", width: 2000, height: 1000)]
                + (tiedReset ? [.init(id: "T", master: "TIE", x: 3000, width: 100, height: 1000, placed: true, locked: true)] : []))
        for (index, port) in ports.enumerated() {
            if tiedReset && port.0 == "rn" {
                snapshot.pins.append(.init(id: "T/Y", cellID: "T", name: "Y", netID: "rn", direction: "output"))
                snapshot.pins.append(.init(id: "U/RN", cellID: "U", name: "RN", netID: "rn", direction: "input"))
                snapshot.nets.append(.init(id: "rn", pinIDs: ["T/Y", "U/RN"], defUse: .signal))
                continue
            }
            let x: Int64 = port.2 == "input" ? 3500 : 3000, y = Int64(100 + index * 200)
            snapshot.pins.append(.init(id: port.0, name: port.0, x: x, y: y, netID: port.0, direction: port.2, accessLayer: 1,
                topPort: .init(rectangle: .init(x: 0, y: 0, width: 100, height: 100), layer: 1,
                    placementX: x - 50, placementY: y - 50, orientation: .n, placementStatus: .fixed, use: port.0 == "clk" ? .clock : .signal)))
            snapshot.pins.append(.init(id: "U/" + port.1, cellID: "U", name: port.1, netID: port.0, direction: port.2))
            snapshot.nets.append(.init(id: port.0, pinIDs: [port.0, "U/" + port.1], isClock: port.0 == "clk", defUse: port.0 == "clk" ? .clock : .signal))
        }
        var request = PhysicalDesignRequest(runID: "sequential-placement-" + kind + refusal,
            inputBindings: [tech, cells, library, pdk, design, constraints, binding],
            design: .init(artifact: design.reference, topDesignName: "top", designDigest: design.reference.digest.hexadecimalValue), constraints: constraints,
            requestedModeIDs: ["functional"], pdk: try .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk), processID: manifest.processID, version: manifest.version),
            stage: .placement, configuration: .init(placementSpacing: 0, preferredRoutingLayers: [1], maximumRoutingLayer: 1,
                implementationConstraints: .init(routeWidth: 100, routeSpacing: 100)), initialSnapshot: snapshot,
            executionIntent: .characterizedTiming, placementTimingProfile: reference, processAssets: ["tech": tech, "cells": cells])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        snapshot = try geometry.bind(snapshot)
        for index in snapshot.pins.indices where snapshot.pins[index].cellID != nil {
            let cell = try #require(snapshot.cells.first { $0.id == snapshot.pins[index].cellID })
            snapshot.pins[index] = try geometry.referencePin(snapshot.pins[index], for: cell)
        }
        request.initialSnapshot = snapshot
        return .init(request: request, store: store, geometry: geometry, profile: profile)
    }

    private static let technology = """
    VERSION 5.8 ;
    UNITS DATABASE MICRONS 1000 ; CAPACITANCE PICOFARADS 1 ; RESISTANCE OHMS 1 ; END UNITS
    SITE unit CLASS CORE ; SIZE 0.1 BY 1 ; SYMMETRY X Y ; END unit
    LAYER m1 TYPE ROUTING ; DIRECTION HORIZONTAL ; PITCH 0.2 ; OFFSET 0.1 ; WIDTH 0.1 ; SPACING 0.1 ;
      RESISTANCE RPERSQ 1 ; CAPACITANCE CPERSQDIST 0.0001 ; EDGECAPACITANCE 0.0001 ; END m1
    END LIBRARY
    """
    private func cellLEF(_ kind: String, tiedReset: Bool) -> String {
        """
        VERSION 5.8 ; UNITS DATABASE MICRONS 1000 ; END UNITS
        MACRO STATE CLASS CORE ; SIZE 2 BY 1 ; SYMMETRY X Y ; SITE unit ;
          PIN D DIRECTION INPUT ; USE SIGNAL ; PORT LAYER m1 ; RECT 0.1 0.1 0.3 0.3 ; END END D
          PIN C DIRECTION INPUT ; USE CLOCK ; PORT LAYER m1 ; RECT 0.5 0.1 0.7 0.3 ; END END C
          \(kind == "ff" ? "PIN RN DIRECTION INPUT ; USE SIGNAL ; PORT LAYER m1 ; RECT 0.9 0.1 1.1 0.3 ; END END RN" : "")
          PIN Q DIRECTION OUTPUT ; USE SIGNAL ; PORT LAYER m1 ; RECT 1.5 0.1 1.7 0.3 ; END END Q
          PIN VPWR DIRECTION INOUT ; USE POWER ; PORT LAYER m1 ; RECT 0.1 0.8 1.9 0.9 ; END END VPWR
          PIN VGND DIRECTION INOUT ; USE GROUND ; PORT LAYER m1 ; RECT 0.1 0.6 1.9 0.7 ; END END VGND
        END STATE
        \(tiedReset ? "MACRO TIE CLASS CORE ; SIZE 0.1 BY 1 ; SYMMETRY X Y ; SITE unit ; PIN Y DIRECTION OUTPUT ; USE SIGNAL ; PORT LAYER m1 ; RECT 0.01 0.1 0.09 0.3 ; END END Y END TIE" : "")
        END LIBRARY
        """
    }
    private func sdc(_ kind: String, refusal: String, tiedReset: Bool) -> String {
        """
        create_clock -name clk -period 10ns -waveform {0ns 5ns} [get_ports clk]
        set_clock_transition -rise 0.2ns [get_clocks clk]
        set_clock_transition -fall 0.2ns [get_clocks clk]
        \(refusal == "ideal-clock" ? "" : "set_propagated_clock [get_clocks clk]")
        set_input_transition 0.2ns [all_inputs]
        \(refusal == "missing-input" ? "" : "set_input_delay -clock clk " + (kind == "ff" ? "1ns" : "4.9ns") + " [get_ports d]")
        \(kind == "ff" && !tiedReset ? "set_input_delay -max 2ns -clock clk [get_ports rn]\nset_input_delay -min 1ns -clock clk [get_ports rn]" : "")
        set_output_delay -max 1ns -clock clk [get_ports q]
        set_output_delay -min 0ns -clock clk [get_ports q]
        """
    }
    private func liberty(_ kind: String, missingHold: Bool, pulse: Bool, tie: String?) -> String {
        func tables() -> String {
            ["cell_rise", "cell_fall"].map { $0 + "(t){values(\"0.1,0.1\",\"0.1,0.1\");}" }.joined()
                + ["rise_transition", "fall_transition"].map { $0 + "(t){values(\"0.2,0.2\",\"0.2,0.2\");}" }.joined()
        }
        func check(_ type: String, _ value: String) -> String {
            "timing(){related_pin:C;timing_type:" + type + ";rise_constraint(c){values(\"" + value + "," + value + "\",\"" + value + "," + value + "\");}fall_constraint(c){values(\"" + value + "," + value + "\",\"" + value + "," + value + "\");}}"
        }
        let edge = kind == "ff" ? "rising" : "falling", value = kind == "ff" ? "0.1" : "-0.2"
        let state = kind == "ff" ? "ff(S,SN){next_state:D;clocked_on:C;clear:\"!RN\";power_down_function:\"!VPWR + VGND\";}"
            : "latch(S,SN){data_in:D;enable:C;power_down_function:\"!VPWR + VGND\";}"
        return """
        library(L){time_unit:"1ns";voltage_unit:"1V";capacitive_load_unit(1,pf);
          nom_process:1;nom_voltage:1;nom_temperature:25;
          operating_conditions(tt){process:1;voltage:1;temperature:25;}
          slew_lower_threshold_pct_rise:20;slew_upper_threshold_pct_rise:80;
          slew_lower_threshold_pct_fall:20;slew_upper_threshold_pct_fall:80;
          input_threshold_pct_rise:50;input_threshold_pct_fall:50;output_threshold_pct_rise:50;output_threshold_pct_fall:50;
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;index_1("0,20");index_2("0,20");}
          lu_table_template(c){variable_1:constrained_pin_transition;variable_2:related_pin_transition;index_1("0,20");index_2("0,20");}
          lu_table_template(pulse){variable_1:related_pin_transition;index_1("0,20");}
          cell(STATE){\(state)
            pg_pin(VPWR){pg_type:primary_power;}pg_pin(VGND){pg_type:primary_ground;}
            pin(C){direction:input;clock:true;capacitance:0.05;
              \(pulse ? "timing(){related_pin:C;timing_type:min_pulse_width;rise_constraint(pulse){values(\"0.5,0.5\");}fall_constraint(pulse){values(\"0.5,0.5\");}}" : "")}
            pin(D){direction:input;capacitance:0.05;\(check("setup_" + edge, value))\(missingHold ? "" : check("hold_" + edge, value))}
            \(kind == "ff" ? "pin(RN){direction:input;capacitance:0.05;" + check("recovery_rising", "0.1") + check("removal_rising", "0.1") + "}" : "")
            pin(Q){direction:output;function:S;related_power_pin:VPWR;related_ground_pin:VGND;power_down_function:"!VPWR + VGND";
              timing(){related_pin:C;timing_type:rising_edge;timing_sense:non_unate;\(tables())}
              \(kind == "latch" ? "timing(){related_pin:D;timing_type:combinational;timing_sense:positive_unate;" + tables() + "}" : "")}
          }
          \(tie.map { "cell(TIE){pin(Y){direction:output;function:\"" + $0 + "\";}}" } ?? "")
        }
        """
    }
}
