import Foundation
import Testing
import PDKCore
import PEXCore
import PEXNative
import CoreSpice
import PhysicalDesignEngine
import DEF
import LogicIR
@testable import PhysicalDesignCore

@Suite("Source-bound passive RC native CTS", .timeLimit(.minutes(2)))
struct CharacterizedNativeCTSTests {
    @Test("actual API routes and measures both clock edges without asserting physical signoff")
    func actualDirectCTS() async throws {
        let (request, store, _, _) = try await fixture(buffered: false)
        let started = ContinuousClock.now
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        #expect(result.payload.claims.geometry == .verified && result.payload.claims.timing == .blocked && result.payload.claims.production == .blocked)
        let binding = try #require(result.payload.physicalDesign?.layoutArtifact)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(binding))
        let tree = try #require(output.clockTrees.first), timing = try #require(tree.timingEstimate), evidence = try #require(timing.observations)
        #expect(tree.sourcePinID == "source" && tree.sinkPinIDs == ["sink"])
        #expect(tree.shortestPathLengthDBU == nil && tree.longestPathLengthDBU == nil)
        #expect(evidence.sinks.count == 2 && evidence.sinks.allSatisfy { $0.latencySeconds > 0 && $0.slewSeconds > 6e-11 })
        #expect(evidence.meshCellCount > 0 && evidence.resistorCount > 0 && evidence.electrodeContactCount > 0)
        #expect(evidence.nets.allSatisfy { $0.crossingDifferenceSeconds <= 1e-12 && $0.statistics.count >= 2 })
        #expect(evidence.qualification == .unqualifiedPhysicalSignoff && evidence.constraintsSatisfied)
        #expect(output.routes.allSatisfy { $0.segments.allSatisfy { $0.widthDBU == 100 } })
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: output.unitsPerMicron)
        let defBinding = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        let parsed = try DEFLibraryReader.read(await store.read(defBinding))
        #expect(parsed.nets.count == output.nets.count && parsed.nets.allSatisfy { !$0.routing.isEmpty })
        if let path = ProcessInfo.processInfo.environment["PHYSICAL_CTS_PROBE_ROOT"] {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for binding in request.inputBindings {
                let destination = root.appending(path: binding.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await store.read(binding).write(to: destination, options: .atomic)
            }
            try PhysicalDesignJSONCodec().encode(request).write(to: root.appending(path: "request.json"), options: .atomic)
            let characterization = try await LocalPhysicalDesignClockTimingModelLoader().load(try #require(request.clockTimingModel), for: outputWithoutTrees(output), from: store)
            let projection = try PhysicalDesignClockConductorProjection(snapshot: output, geometry: geometry, characterization: characterization, selectedPins: ["source", "sink"])
            let graph = projection.electrodes, network = graph.network
            let dump = ClockOracleDump(nodeCount: network.nodes.count,
                resistors: network.resistors.map { .init(a: $0.nodeA, b: $0.nodeB, value: $0.ohms) },
                capacitors: network.capacitors.map { .init(a: $0.nodeA, b: $0.nodeB, value: $0.farads) },
                contacts: graph.contacts.map { .init(a: network.nodes.count + $0.portIndex, b: $0.nodeIndex, value: $0.ohms) },
                sourceNode: network.nodes.count + (try #require(graph.ports.firstIndex { $0.terminal.nodeName.value == "source" })),
                sinkNode: network.nodes.count + (try #require(graph.ports.firstIndex { $0.terminal.nodeName.value == "sink" })),
                inputCapacitance: try characterization.library.pinCapacitance(cell: "INV_X1", pin: "A"),
                evidence: evidence)
            try PhysicalDesignJSONCodec().encode(dump).write(to: root.appending(path: "oracle.json"), options: .atomic)
        }
        print("CTS actual direct elapsed: \(started.duration(to: .now)); latencyPS=\(timing.estimatedLatencyPS); savedScalars=\(evidence.nets.flatMap(\.statistics).reduce(0) { $0 + $1.savedScalars })")
    }
    @Test("actual buffer cell characterization composes explicit PWL with distributed RC")
    func actualBufferedCTS() async throws {
        let (request, store, _, _) = try await fixture(buffered: true)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let binding = try #require(result.payload.physicalDesign?.layoutArtifact)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(binding))
        let tree = try #require(output.clockTrees.first), evidence = try #require(tree.timingEstimate?.observations)
        #expect(tree.bufferCellIDs.count == 1 && output.cells.contains { $0.isClockBuffer && $0.master == "BUF_EXACT" })
        #expect(evidence.nets.count == 4 && evidence.sinks.count == 2 && evidence.cells.count == 2)
        #expect(abs(try #require(evidence.cells.first { $0.outputEdge == "rise" }).delaySeconds - 2e-10) < 1e-23)
        #expect(abs(try #require(evidence.cells.first { $0.outputEdge == "fall" }).delaySeconds - 4e-10) < 1e-23)
        #expect(evidence.sinks.first { $0.rootEdge == "fall" }!.latencySeconds > evidence.sinks.first { $0.rootEdge == "rise" }!.latencySeconds)
        #expect(evidence.driverAssumption.contains("caller-declared") && evidence.driverAssumption.contains("no CCS"))
    }
    @Test("unequal physical sink paths produce measured nonzero rise and fall skew")
    func actualFanoutSkew() async throws {
        let (request, store, _, _) = try await fixture(buffered: false, secondSink: true)
        let started = ContinuousClock.now
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let binding = try #require(result.payload.physicalDesign?.layoutArtifact)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(binding))
        let timing = try #require(output.clockTrees.first?.timingEstimate), evidence = try #require(timing.observations)
        #expect(evidence.sinks.count == 4 && timing.estimatedSkewPS > 1)
        for edge in ["rise", "fall"] {
            let near = try #require(evidence.sinks.first { $0.pinID == "sink" && $0.rootEdge == edge })
            let far = try #require(evidence.sinks.first { $0.pinID == "sink2" && $0.rootEdge == edge })
            #expect(far.arrivalSeconds > near.arrivalSeconds && far.waveform != near.waveform)
        }
        print("CTS actual fanout elapsed: \(started.duration(to: .now)); skewPS=\(timing.estimatedSkewPS); mesh=\(evidence.meshCellCount); statistics=\(evidence.nets.flatMap(\.statistics))")
    }
    @Test("source-declared distinct thresholds retain signed crossing latency")
    func signedThresholdLatency() async throws {
        let (request, store, _, _) = try await fixture(buffered: false, distinctThresholds: true)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let binding = try #require(result.payload.physicalDesign?.layoutArtifact)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(binding))
        let timing = try #require(output.clockTrees.first?.timingEstimate)
        #expect(timing.estimatedLatencyPS < 0 && timing.observations!.sinks.allSatisfy { $0.latencySeconds < 0 })
    }
    @Test("bad source, clock model, constraint and resource inputs publish no candidate", arguments: ["corner", "waveform", "clock", "electrode", "limits", "constraints", "missing"])
    func rejection(reason: String) async throws {
        var (request, store, model, reference) = try await fixture(buffered: false)
        switch reason {
        case "corner": model.cornerID = "unknown"
        case "waveform": model.riseReversedForTest()
        case "clock": model.clocks[0].sourcePinID = "sink"
        case "electrode": model.electrodes[0].faces = [.init(side: .minX, coordinate: 999, begin: 100, end: 700)]
        case "limits": model.numerics.transient = .init(maximumAcceptedSteps: 1, maximumSolveAttempts: 1, maximumNewtonIterations: 1,
            maximumSavedScalars: 1, maximumMatrixDimension: 1, maximumWorkUnits: 1, maximumBreakpoints: 1)
        case "constraints": model.constraints.maximumLatencySeconds = 1e-18
        default: request.clockTimingModel = nil
        }
        if reason != "missing" {
            let changed = try await store.registerInput(try PhysicalDesignJSONCodec().encode(model), relativePath: "inputs/changed-model.json", kind: .technology, format: .json)
            reference.modelArtifact = changed; request.clockTimingModel = reference
            request.inputs.append(changed.reference); request.inputBindings.append(changed)
        }
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
        #expect(result.payload.physicalDesign == nil && result.payload.claims.timing == .blocked)
    }
    @Test("pre-cancelled native CTS never publishes artifacts")
    func cancellation() async throws {
        let (request, store, _, _) = try await fixture(buffered: false)
        let task = Task { try await PhysicalDesignEngine(artifactStore: store).execute(request) }
        task.cancel()
        let result = try await task.value
        #expect(result.status == .cancelled && result.artifactBindings.isEmpty)
    }
    func fixture(buffered: Bool, secondSink: Bool = false, distinctThresholds: Bool = false) async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore, PhysicalDesignClockTimingModel, PhysicalDesignClockTimingModelReference) {
        let (_, base, store) = try await ProcessGeometryTests().fixture(replacement: "buffer", routingPorts: true)
        let calibration = try await store.registerInput(Data("analytical passive sheet calibration".utf8), relativePath: "inputs/calibration.txt", kind: .technology, format: .json)
        let range = PEXDimensionRangeMeters(minimumMeters: 1e-12, maximumMeters: 1)
        let electrical = PEXElectricalModel(law: .rectilinearSheetV1, processName: "fixture-130nm", cornerID: "tt", temperatureKelvin: 298.15,
            voltageVolts: 1, parameters: [:], referenceNodeName: "0", calibrationArtifacts: [calibration.reference.id],
            conductors: [("M1", 0.0), ("M2", 2e-6)].map { .init(layerName: $0.0, bottomHeightMeters: $0.1, thicknessMeters: 1e-6,
                resistivityOhmMeters: 1e-4, groundAreaFaradsPerSquareMeter: 1e-4, groundPerimeterFaradsPerMeter: 1e-10, widthRange: range, lengthRange: range) },
            vias: [.init(viaName: "hv", cutLayerName: "C1", bottomLayerName: "M1", topLayerName: "M2", resistanceOhmsPerCut: 1,
                cutWidthRange: range, cutHeightRange: range)], couplings: [("M1", "M1"), ("M1", "M2"), ("M2", "M2")].map {
                .init(firstLayerName: $0.0, secondLayerName: $0.1, areaFaradsPerSquareMeter: 1e-5, sidewallFarads: 1e-16, gapRange: range) })
        let rc = TechnologyIR(processName: "fixture-130nm", stack: [("M1", 0), ("C1", 1), ("M2", 2)].map { .init(name: $0.0, order: $0.1) },
            logicalToPhysicalLayerMap: ["H": "M1", "V": "M2", "C": "C1"], vias: [.init(name: "hv", topLayer: "M2", bottomLayer: "M1")],
            defaultExtractionRules: .default, backendHints: [:], electricalModels: [electrical])
        let rcBinding = try await store.registerInput(try PhysicalDesignJSONCodec().encode(rc), relativePath: "inputs/rc.json", kind: .technology, format: .json)
        let library = try await store.registerInput(Data((distinctThresholds ? Self.liberty.replacingOccurrences(of: "time_unit :", with: "input_threshold_pct_rise : 10; input_threshold_pct_fall : 90; output_threshold_pct_rise : 90; output_threshold_pct_fall : 10; time_unit :") : Self.liberty).utf8), relativePath: "inputs/clock.lib", kind: .technology, format: .liberty)
        let originalManifest = try #require(base.inputBindings.first { $0.reference == base.pdk.manifest })
        var manifest = try PDKManifestCodec.decode(data: await store.read(originalManifest))
        if secondSink {
            let mapping = try #require(manifest.crossViewMappings.firstIndex { $0.mappingID == "cells" })
            manifest.crossViewMappings[mapping].physicalNames.append("SINK_EXACT")
        }
        var processAssets = base.processAssets
        let cells = try #require(processAssets["cells"])
        var changedCells = try #require(String(data: await store.read(cells), encoding: .utf8))
            .replacingOccurrences(of: "RECT 0.1 0.1 0.2 0.2", with: "RECT 0.1 0.1 0.3 0.7")
            .replacingOccurrences(of: "RECT 0.5 0.1 0.6 0.2", with: "RECT 0.5 0.1 0.7 0.7")
        if secondSink {
            changedCells = changedCells.replacingOccurrences(of: "END LIBRARY", with: "MACRO SINK_EXACT CLASS CORE ; SIZE 2 BY 1 ; SYMMETRY X Y R90 ; SITE unit ; PIN A DIRECTION INPUT ; USE CLOCK ; PORT LAYER metH ; RECT 0.1 0.1 0.7 0.7 ; END END A END SINK_EXACT\nEND LIBRARY")
        }
        let cellBinding = try await store.registerInput(Data(changedCells.utf8), relativePath: "inputs/cts-cells.lef", kind: .technology, format: .lef)
        processAssets["cells"] = cellBinding
        let asset = try #require(manifest.assets.firstIndex { $0.assetID == "cells" })
        manifest.assets[asset].sha256 = cellBinding.reference.digest.hexadecimalValue; manifest.assets[asset].byteCount = Int64(changedCells.utf8.count)
        for (id, binding) in [("rc", rcBinding), ("liberty", library)] {
            manifest.assets.append(.init(assetID: id, role: id == "liberty" ? .liberty : .extraction, path: id, kind: binding.descriptor.kind, format: binding.descriptor.format,
                sha256: binding.reference.digest.hexadecimalValue, byteCount: Int64(binding.reference.byteCount)))
        }
        manifest.corners = [.init(cornerID: "tt", pvt: .init(process: .init(name: "typical", nominal: true), voltage: 1, temperatureCelsius: 25), rcCorner: "tt", assetIDs: ["rc", "liberty"])]
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/cts-process.json", kind: .technology, format: .json)
        var snapshot = PhysicalDesignSnapshot(topCell: base.design.topDesignName, unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 10000, height: 5000), core: .init(x: 0, y: 0, width: 10000, height: 5000),
            rows: [.init(id: "row", originX: 0, originY: 0, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit")],
            cells: [.init(id: "driver", master: "INV_X1", x: 0, y: 0, width: 2000, height: 1000, placed: true),
                .init(id: "receiver", master: secondSink ? "SINK_EXACT" : "INV_X1", x: 4000, y: 0, width: 2000, height: 1000, placed: true)],
            pins: [.init(id: "source", cellID: "driver", name: "Y", netID: "CLK", direction: "output"),
                .init(id: "sink", cellID: "receiver", name: "A", netID: "CLK")], nets: [.init(id: "CLK", pinIDs: ["source", "sink"], isClock: true)])
        snapshot.implementationState = .init(tracks: [.init(id: "h", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 25),
            .init(id: "v", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 25)])
        if secondSink {
            snapshot.cells.append(.init(id: "farReceiver", master: "SINK_EXACT", x: 7000, y: 0, width: 2000, height: 1000, placed: true))
            snapshot.pins.append(.init(id: "sink2", cellID: "farReceiver", name: "A", netID: "CLK"))
            snapshot.nets[0].pinIDs.append("sink2")
        }
        let designBinding = try await store.registerInput(try PhysicalDesignJSONCodec().encode(snapshot), relativePath: "inputs/clock-design.json", kind: .netlist, format: .json)
        let constraintsBinding = try await store.registerInput(Data("create_clock -name CLK -period 5 [get_ports CLK]".utf8), relativePath: "inputs/clock.sdc", kind: .constraint, format: .sdc)
        var design = base.design
        design.artifact = designBinding.reference; design.designDigest = designBinding.reference.digest.hexadecimalValue
        let numerics = PhysicalDesignClockNumerics(stopTimeSeconds: 5e-9, maximumTimeStepSeconds: 1e-11, minimumTimeStepSeconds: 1e-18,
            relativeTolerance: 1e-5, voltageTolerance: 1e-9, currentTolerance: 1e-15, lteTolerance: 1, maximumNewtonIterationsPerSolve: 20,
            maximumStepReductions: 30, maximumRefinements: 4, crossingAgreementSeconds: 1e-12, maximumCellSpanDBU: 500,
            maximumInputBytes: 1_000_000, maximumProjectionRecords: 10_000, maximumGeometryProbes: 1_000_000,
            extraction: .init(maximumMeshCells: 10_000), electrodes: .init(maximumContacts: 10_000),
            transient: .init(maximumAcceptedSteps: 100_000, maximumSolveAttempts: 300_000, maximumNewtonIterations: 1_000_000,
                maximumSavedScalars: 10_000_000, maximumMatrixDimension: 1000, maximumWorkUnits: 10_000_000_000, maximumBreakpoints: 100))
        let model = PhysicalDesignClockTimingModel(processID: "fixture-130nm", pdkVersion: "1", cornerID: "tt", rcCornerID: "tt", libertyAssetID: "liberty", rcAssetID: "rc", rcParameters: [:],
            pdkManifestDigest: pdk.reference.digest.hexadecimalValue, rcModelDigest: rcBinding.reference.digest.hexadecimalValue,
            cellLibraryDigest: library.reference.digest.hexadecimalValue, method: .passiveLinearRCTransientV1, quietBoundary: .allOtherConductorsIdealReference,
            clocks: [.init(netID: "CLK", sourcePinID: "source", sinkPinIDs: secondSink ? ["sink", "sink2"] : ["sink"], rise: [.init(time: 0, voltage: 0), .init(time: distinctThresholds ? 3e-9 : 1e-10, voltage: 1)],
                fall: [.init(time: 0, voltage: 1), .init(time: distinctThresholds ? 3e-9 : 1e-10, voltage: 0)], topology: buffered ? .bufferEachSink : .direct,
                bufferMaster: buffered ? "BUF_EXACT" : nil, bufferRiseShape: [.init(time: 0, voltage: 0), .init(time: 1, voltage: 1)],
                bufferFallShape: [.init(time: 0, voltage: 1), .init(time: 1, voltage: 0)])], electrodes: [
                .init(master: "INV_X1", pin: "Y", faces: [.init(side: .minX, coordinate: 1200, begin: 100, end: 700)]),
                .init(master: "INV_X1", pin: "A", faces: [.init(side: .maxX, coordinate: 700, begin: 100, end: 700)]),
                .init(master: "SINK_EXACT", pin: "A", faces: [.init(side: .maxY, coordinate: 700, begin: 100, end: 700)]),
                .init(master: "BUF_EXACT", pin: "DIN", faces: [.init(side: .maxX, coordinate: 300, begin: 100, end: 700)]),
                .init(master: "BUF_EXACT", pin: "Q", faces: [.init(side: .minX, coordinate: 500, begin: 100, end: 700)])],
            constraints: .init(maximumLatencySeconds: 4e-9, maximumSkewSeconds: 1e-9, maximumSlewSeconds: 4e-9, maximumLoadFarads: 1e-11), numerics: numerics)
        let modelBinding = try await store.registerInput(try PhysicalDesignJSONCodec().encode(model), relativePath: "inputs/model.json", kind: .technology, format: .json)
        let reference = PhysicalDesignClockTimingModelReference(modelArtifact: modelBinding, pdkManifestArtifact: pdk, rcModelArtifact: rcBinding,
            cellLibraryArtifact: library, calibrationArtifacts: [calibration], processID: "fixture-130nm", pdkVersion: "1", cornerID: "tt")
        var request = PhysicalDesignRequest(runID: "actual-cts", inputBindings: [designBinding, constraintsBinding, pdk],
            design: design, constraints: constraintsBinding, requestedModeIDs: base.requestedModeIDs,
            pdk: .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk), processID: "fixture-130nm", version: "1", digest: pdk.reference.digest.hexadecimalValue),
            stage: .clockTreeSynthesis, initialSnapshot: snapshot, clockTimingModel: reference, processAssets: processAssets)
        request.executionIntent = .characterizedTiming
        request.configuration.preferredRoutingLayers = secondSink ? [2] : [2, 3]; request.configuration.maximumRoutingLayer = 3
        request.configuration.implementationConstraints = .init(clockBufferMaster: "BUF_EXACT", clockRouteLayer: 2, routeWidth: 100, routeSpacing: 100)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        snapshot = try geometry.bind(snapshot)
        for index in snapshot.pins.indices {
            let cell = try #require(snapshot.cells.first { $0.id == snapshot.pins[index].cellID })
            snapshot.pins[index] = try geometry.referencePin(snapshot.pins[index], for: cell)
        }
        request.initialSnapshot = snapshot
        return (request, store, model, reference)
    }
    private func outputWithoutTrees(_ value: PhysicalDesignSnapshot) -> PhysicalDesignSnapshot {
        var copy = value; copy.clockTrees = []; return copy
    }
    private struct ClockOracleDump: Codable {
        struct Element: Codable { let a: Int; let b: Int?; let value: Double }
        let nodeCount: Int
        let resistors: [Element]
        let capacitors: [Element]
        let contacts: [Element]
        let sourceNode: Int
        let sinkNode: Int
        let inputCapacitance: Double
        let evidence: PhysicalDesignClockTimingEvidence
    }
    static let liberty = """
    library (fixture) {
      time_unit : "1ns"; capacitive_load_unit (1, pf);
      lu_table_template (table) { variable_1 : input_net_transition; variable_2 : total_output_net_capacitance; index_1 ("0.001, 10"); index_2 ("0.001, 100"); }
      cell (INV_X1) { pin (A) { direction : input; clock : true; capacitance : 0.1; } pin (Y) { direction : output; } }
      cell (SINK_EXACT) { pin (A) { direction : input; clock : true; capacitance : 0.1; } }
      cell (BUF_EXACT) {
        pin (DIN) { direction : input; capacitance : 0.05; }
        pin (Q) { direction : output;
          timing () { related_pin : "DIN"; timing_sense : positive_unate;
            cell_rise (table) { values ("0.2, 0.2", "0.2, 0.2"); }
            cell_fall (table) { values ("0.4, 0.4", "0.4, 0.4"); }
            rise_transition (table) { values ("0.12, 0.12", "0.12, 0.12"); }
            fall_transition (table) { values ("0.18, 0.18", "0.18, 0.18"); }
          }
        }
      }
    }
    """
}
private extension PhysicalDesignClockTimingModel {
    mutating func riseReversedForTest() { clocks[0].rise[1].voltage = -1 }
}
