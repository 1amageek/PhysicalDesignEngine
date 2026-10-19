import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import PhysicalDesignLogicHandoff
import Foundation
import Darwin
import DEF
import LogicEngineCore
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PDKCore
import PEXCore
import PEXNative
import PEXParsers
import STAEngine
import TimingCore
import Testing
@testable import PhysicalDesignCore

@Suite("Native CTS actual-cell functional handoff", .serialized, .timeLimit(.minutes(4)))
struct NativeCTSLogicEquivalenceTests {
    private static let buffer = "sky130_fd_sc_hd__buf_1"
    private static let inverter = "sky130_fd_sc_hd__inv_1"
    private static let flipFlop = "sky130_fd_sc_hd__dfxtp_1"
    private static let pg: [LibertyPGCondition] = [
        .init(pin: "VPWR", sourcePGType: "primary_power", value: true),
        .init(pin: "VGND", sourcePGType: "primary_ground", value: false),
        .init(pin: "VPB", sourcePGType: "nwell", value: true),
        .init(pin: "VNB", sourcePGType: "pwell", value: false)
    ]
    private static let tt: [STACharacterizationBinding] = [
        .init(cornerID: "tt", conditionName: "tt_025C_1v80", requiredNumericProcess: 1)
    ]
    private static let process = "sky130-selected-cts-functions-analytical-fixture-rc"
    private struct Fixture {
        let root: URL
        let synthesis: LogicVerifiedSynthesis
        let request: PhysicalDesignRequest
        let store: InMemoryPhysicalDesignArtifactStore
        let geometry: PhysicalDesignProcessGeometry
        let correspondence: PhysicalLogicECOCorrespondence
        let model: PhysicalDesignClockTimingModel
        let reference: PhysicalDesignClockTimingModelReference
    }
    private struct SelectionReport: Decodable {
        struct Source: Decodable {
            let selectedFile: String
            let selectedSHA256: String
            let selectedByteCount: Int
            let originSHA256: String
        }
        let sources: [Source]
    }
    private struct Running: LogicRunControlling { func checkpoint() throws(LogicKernelError) {} }
    private func captureProfile() throws -> PhysicalDesignClockCaptureLimits {
        // One no-relaxation run measured both actual routed rectangle inventories.
        // The derived case bounds the primary case; no successful-contact count is used.
        let polygons = 23_561, points = 94_284, pins = 7
        func add(_ lhs: Int, _ rhs: Int) throws -> Int {
            let value = lhs.addingReportingOverflow(rhs)
            return try #require(!value.overflow ? value.partialValue : nil)
        }
        func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
            let value = lhs.multipliedReportingOverflow(by: rhs)
            return try #require(!value.overflow ? value.partialValue : nil)
        }
        let entries = try add(add(polygons, points), multiply(pins, 5))
        let contacts = try add(multiply(polygons, polygons - 1) / 2, multiply(polygons, pins))
        return .init(maximumHierarchyOccurrences: 1, maximumHierarchyObjects: 100_000,
            maximumHierarchyGeometryPoints: 1_000_000, maximumHierarchyDepth: 1,
            maximumDecompositionInputEntries: entries, maximumDecompositionEdgeProbes: 1_000_000,
            maximumDecompositionOutputBands: try add(polygons, pins), maximumTechnologyRecords: 100_000,
            maximumFootprints: polygons, maximumContactProbes: contacts)
    }
    private func transientWorkCeiling(extraction: NativePEXCalculationLimits, electrodes: NativePEXElectrodeLimits,
        maximumProjectionRecords: Int, maximumMatrixDimension: Int, maximumNewtonIterations: Int) throws -> Int {
        func add(_ lhs: Int, _ rhs: Int) throws -> Int {
            let value = lhs.addingReportingOverflow(rhs)
            return try #require(!value.overflow ? value.partialValue : nil)
        }
        func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
            let value = lhs.multipliedReportingOverflow(by: rhs)
            return try #require(!value.overflow ? value.partialValue : nil)
        }
        let dimension = maximumMatrixDimension
        let entries = try multiply(dimension, dimension)
        let devices = try add(add(extraction.maximumNetworkElements, electrodes.maximumContacts), add(maximumProjectionRecords, 1))
        let iterationWork = try add(add(multiply(entries, dimension), multiply(2, entries)),
            add(multiply(2, devices), multiply(8, dimension)))
        // Each LTE trial follows at least one admitted Newton iteration.
        let iterationAndTrialWork = try add(iterationWork, multiply(20, dimension))
        let requestWork = try multiply(iterationAndTrialWork, maximumNewtonIterations)
        try #require(devices == 8_110_001 && iterationWork == 1_018_228_002)
        try #require(requestWork == 1_018_248_002_000_000)
        return requestWork
    }
    private func context() throws -> LogicKernelContext {
        .init(limits: try .init(maximums: Dictionary(uniqueKeysWithValues:
            LogicResource.allCases.map { ($0, UInt64(1_000_000_000)) })), control: Running())
    }
    private func limits() throws -> PhysicalLogicHandoffLimits {
        try .init(maximumInstances: 100, maximumPins: 1000, maximumNets: 1000)
    }
    private func source(_ name: String) throws -> Data {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: root.appending(path: "NativeCTS/Sky130/" + name))
    }
    private func cleanup(_ root: URL) {
        if ProcessInfo.processInfo.environment["PHYSICAL_NATIVE_CTS_EVIDENCE_ROOT"] != nil { return }
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
    }

    private func timingInput(_ data: Data, name: String, format: ArtifactFormat, root: URL,
                             kind: ArtifactKind = .constraint) throws -> TimingArtifactBinding {
        let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: data, using: .sha256),
            byteCount: UInt64(data.count), descriptor: .init(role: .input, kind: kind, format: format))
        try data.write(to: root.appending(path: name))
        return try .init(reference: reference, availability: .local(artifactID: reference.id,
            rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier), relativePath: .init(segments: [name])))
    }
    private func retainTimingInput(_ binding: PhysicalDesignArtifactBinding,
                                   store: InMemoryPhysicalDesignArtifactStore, root: URL) async throws -> TimingArtifactBinding {
        let target = root.appending(path: binding.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await store.read(binding).write(to: target)
        return try .init(reference: binding.reference, availability: .local(artifactID: binding.reference.id,
            rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier),
            relativePath: .init(segments: binding.path.split(separator: "/").map(String.init))))
    }
    private func staConstraints(clock: String, data: [String], outputs: [String], propagated: Bool) -> String {
        var lines = ["create_clock -name c -period 10ns -waveform {0ns 5ns} [get_ports \(clock)]",
            "set_clock_transition -rise 0.2ns [get_clocks c]", "set_clock_transition -fall 0.2ns [get_clocks c]",
            "set_input_transition 0.2ns [all_inputs]"]
        if propagated { lines.append("set_propagated_clock [get_clocks c]") }
        for pin in data {
            lines.append("set_input_delay -max 1ns -clock c [get_ports \(pin)]")
            lines.append("set_input_delay -min 1ns -clock c [get_ports \(pin)]")
        }
        for pin in outputs {
            lines.append("set_output_delay -max 1ns -clock c [get_ports \(pin)]")
            lines.append("set_output_delay -min 0ns -clock c [get_ports \(pin)]")
        }
        return lines.joined(separator: "\n")
    }
    private struct ExternalLoadReceipt: Codable {
        let library: ArtifactReference
        let cell: String
        let pin: String
        let capacitanceFarads: Double
        let terminalNames: [String]
        let originalProjection: ArtifactReference
        let loadedParasitics: ArtifactReference
        let candidateDigest: ContentDigest
        let scope: String
    }
    private func requireSavedSTABinding(_ assessment: PhysicalLogicECOAssessment, fixture: Fixture, name: String) async throws {
        let candidate = assessment.candidate
        let codec = PhysicalDesignJSONCodec()
        let instances = try candidate.cells.map { cell in
            var connections: [String: String] = [:]
            for pin in candidate.pins where pin.cellID == cell.id { connections[pin.name] = try #require(pin.netID) }
            return TimingDesign.Instance(name: cell.id, cell: cell.master, connections: connections)
        }
        let ports = try candidate.pins.filter { $0.cellID == nil }.map {
            TimingDesign.Port(name: $0.name, direction: $0.direction == "input" ? .input : .output, net: try #require($0.netID))
        }
        let graph = TimingDesign(topDesignName: candidate.topCell, ports: ports, instances: instances,
            nets: candidate.nets.map { .init(name: $0.id) })
        let map = assessment.correspondence
        let clock = try fixture.synthesis.mapped.withTables { _, _, _, ports, _, _ in
            try #require(ports.count == 3 && ports[1].direction == .input && ports[1].bits.count == 1)
            let id = try #require(map.portPinIDs[ports[1].id]?.first)
            return try #require(candidate.pins.first { $0.id == id }?.name)
        }
        let outputs = graph.ports.filter { $0.direction == .output }.map(\.name)
        let data = graph.ports.filter { $0.direction == .input && $0.name != clock }.map(\.name)
        let library = fixture.reference.cellLibraryArtifact
        let manifest = fixture.reference.pdkManifestArtifact
        let timingLibrary = try await retainTimingInput(library, store: fixture.store, root: fixture.root)
        let timingManifest = try await retainTimingInput(manifest, store: fixture.store, root: fixture.root)
        try #require(timingLibrary.reference == fixture.synthesis.request.library.reference)
        var supplies: [STAOperatingSupplyAssumption] = []
        for cell in candidate.cells {
            for pg in Self.pg {
                supplies.append(try .init(instance: cell.id, cell: cell.master, cornerID: "tt", library: library.reference,
                    pin: pg.pin, sourcePGType: pg.sourcePGType, value: pg.value ? .one : .zero))
            }
        }
        let rcOptions = try STADistributedRCOptions(maximumTimeStep: 2e-11, stopTime: 2e-7,
            crossingTolerance: 2e-12, maximumRefinements: 10, maximumNodes: 16, maximumSteps: 2_000_000)
        let profile = PhysicalDesignPlacementTimingProfile.sourceBoundSequential(manifest: manifest.reference,
            library: library, libertyAssetID: "liberty", capacitanceAssetID: "tech", cornerID: "tt", rcCornerID: "analytical",
            conditionName: "tt_025C_1v80", wireLayer: 1, wireWidthDBU: 170,
            operatingSupplyAssumptions: supplies, distributedRC: rcOptions)
        let profileBinding = try await fixture.store.registerInput(codec.encode(profile),
            relativePath: "inputs/\(name)-join-profile.json", kind: .technology, format: .json)
        _ = try await retainTimingInput(profileBinding, store: fixture.store, root: fixture.root)
        let reference = PhysicalDesignPlacementTimingReference(artifact: profileBinding,
            maximumInputBytes: 2_000_000, maximumLiveBytes: 50_000_000, maximumWorkUnits: 200_000_000,
            maximumPathWorkUnitsPerAnalysis: 5_000_000, maximumPathStates: 10_000,
            maximumEvidenceBytes: 8_000_000, timeoutNanoseconds: 60_000_000_000)
        let budget = try NativePhysicalDesignPlacementTimingBudget(reference)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: fixture.request, store: fixture.store))
        let projection = try NativePhysicalDesignPlacementRCProjection(profile: profile, inputs: inputs,
            geometry: fixture.geometry).project(candidate, graph: graph, budget: budget)
        defer { withExtendedLifetime(projection) {} }
        let raw = try timingInput(projection.spef, name: "\(name)-pre-route-raw.spef", format: .spef,
            root: fixture.root, kind: .parasitics)
        try #require(raw.reference == projection.reference)
        let parsed = try LibertyParser().parse(await fixture.store.read(library))
        let load = try #require(parsed.cells[Self.flipFlop]?.pin(named: "D")?.capacitance)
        try #require(load.isFinite && load > 0)
        var nets = projection.network.nets, elements = projection.network.elements
        for (index, port) in graph.ports.enumerated() where port.direction == .output {
            let netIndex = try #require(nets.firstIndex { $0.name == NetName(port.netName) })
            let net = nets[netIndex]
            try #require(net.nodes.contains { $0.name == NodeName(port.name) })
            elements.append(.init(id: "caller-output-load-\(index)", kind: .capacitor,
                nodeA: .init(netName: net.name, nodeName: .init(port.name)), nodeB: nil, value: load, source: .userDefined))
            nets[netIndex] = .init(name: net.name, nodes: net.nodes, totalGroundCapF: net.totalGroundCapF + load,
                totalCouplingCapF: net.totalCouplingCapF, totalResistanceOhm: net.totalResistanceOhm)
        }
        let loaded = ParasiticIR(version: projection.network.version, cornerID: projection.network.cornerID,
            units: projection.network.units, nets: nets, elements: elements,
            metadata: projection.network.metadata.merging(["externalLoad": "caller-selected actual dfxtp D capacitance"]) { _, new in new })
        let spef = try SPEFWriter(options: .init(designName: candidate.topCell, program: "NativeCTSLogicEquivalenceTests",
            terminalTokenProfile: .canonical)).write(loaded)
        let parasitics = try timingInput(Data(spef.utf8), name: "\(name)-pre-route-loaded.spef", format: .spef,
            root: fixture.root, kind: .parasitics)
        let receipt = ExternalLoadReceipt(library: library.reference, cell: Self.flipFlop, pin: "D",
            capacitanceFarads: load, terminalNames: outputs, originalProjection: raw.reference,
            loadedParasitics: parasitics.reference, candidateDigest: projection.snapshotDigest,
            scope: "source-coefficient pre-route star RC plus explicit caller load; not routed extraction or qualification")
        try codec.encode(receipt).write(to: fixture.root.appending(path: "\(name)-external-load.json"))
        let design = try timingInput(codec.encode(graph), name: "\(name)-sta-design.json", format: .json,
            root: fixture.root, kind: .netlist)
        let constraints = try timingInput(Data(staConstraints(clock: clock, data: data, outputs: outputs,
            propagated: true).utf8), name: "\(name)-sta.sdc", format: .sdc, root: fixture.root)
        let request = try STARequest(runID: "actual-cts-\(name)-join", design: design, topDesignName: candidate.topCell,
            libraries: [.init(artifact: timingLibrary, cornerIDs: ["tt"])], constraints: constraints,
            requestedModeIDs: ["functional"], requestedCornerIDs: ["tt"], pdkManifest: timingManifest,
            processID: Self.process, pdkVersion: try #require(fixture.synthesis.request.operatingProcessScope).pdkVersion,
            parasitics: parasitics, analysisKinds: [.setup, .hold, .recovery, .removal, .pulseWidth],
            characterizationPolicy: .requireObservedConditions, characterizationBindings: Self.tt,
            distributedRC: rcOptions, requireStrictSourceEvidence: true, operatingSupplyAssumptions: supplies)
        try codec.encode(request).write(to: fixture.root.appending(path: "\(name)-sta-request.json"))
        let reader = FileSystemTimingArtifactReader(workspaceRoot: fixture.root)
        let engine = NativeSTAEngine(reader: reader)
        // Execution and validator replay each receive the unchanged finite per-analysis allowance.
        try budget.chargeWork(reference.maximumPathWorkUnitsPerAnalysis * 2)
        let prepared = try await engine.prepare(request, resources: .init(reader: reader,
            sourceLimits: try .init(maximumNestingDepth: 64), sourceResources: budget,
            limits: try .init(maximumInputBytes: reference.maximumInputBytes, maximumPathStates: reference.maximumPathStates,
                maximumPathWorkUnits: reference.maximumPathWorkUnitsPerAnalysis)))
        let result = try await engine.execute(prepared)
        try #require(result.status == .completed, "\(result.diagnostics)")
        let resultURL = fixture.root.appending(path: "\(name)-sta-result.json")
        try codec.encode(result).write(to: resultURL)
        let reloaded = try codec.decode(STAExecutionResult.self, from: Data(contentsOf: resultURL))
        var run = try context()
        try await assessment.requireSTABinding(to: prepared, result: reloaded, validator: engine,
            limits: limits(), context: &run)
        #expect(reloaded.payload.sourceEvidence != nil && !reloaded.payload.clockObservations.isEmpty)
        #expect(reloaded.payload.wireCoverage.allSatisfy { $0.model != .idealClock && $0.model != .uncovered })
        #expect(reloaded.payload.effectiveConfiguration?.operatingSupplyAssumptions.count == candidate.cells.count * Self.pg.count)
        print("NATIVE_CTS_SAVED_STA_BINDING_OK path=\(name) instances=\(candidate.cells.count) rc=preRouteProjected")
    }

    private func fixture(derived: Bool = false, disconnected: Bool = false, ambiguous: Bool = false) async throws -> Fixture {
        let helper = PhysicalLogicHandoffTests()
        let root: URL
        if let retainedRoot = ProcessInfo.processInfo.environment["PHYSICAL_NATIVE_CTS_EVIDENCE_ROOT"] {
            root = URL(fileURLWithPath: retainedRoot).appending(path: "native-cts-\(derived ? "derived" : "primary")-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else { root = try helper.temporary() }
        var retained = false
        defer { if !retained { cleanup(root) } }
        let text = derived
            ? "module top(input [1:0] d,input c,output logic [1:0] q);wire nc;assign nc=~c;always_ff @(posedge nc) q<=d;endmodule"
            : "module top(input [1:0] d,input c,output logic [1:0] q);always_ff @(posedge c) q<=d;endmodule"
        let sourceBinding = try helper.input(Data(text.utf8), name: "top.sv", format: .systemVerilog, root: root)
        let libraryBytes = try source("timing.lib")
        let runtimeLimits = helper.limits()
        let store = InMemoryPhysicalDesignArtifactStore()
        let technology = try await store.registerInput(source("technology.lef"), relativePath: "inputs/selected-tech.lef", kind: .technology, format: .lef)
        var cellBytes = try source("cells.lef")
        if disconnected {
            cellBytes = Data(String(decoding: cellBytes, as: UTF8.self)
                .replacingOccurrences(of: "RECT 1.115 0.760 1.295 1.560", with: "RECT 1.115 0.860 1.295 1.460").utf8)
        }
        if ambiguous {
            cellBytes = Data(String(decoding: cellBytes, as: UTF8.self)
                .replacingOccurrences(of: "RECT 1.025 1.560 1.295 2.465 ;", with: "RECT 1.025 1.560 1.295 2.465 ;\n        RECT 1.025 1.560 1.295 2.465 ;").utf8)
        }
        let cellSource = try await store.registerInput(cellBytes, relativePath: disconnected ? "inputs/disconnected-cells.lef" : "inputs/selected-cells.lef", kind: .technology, format: .lef)
        let liberty = try await store.registerInput(libraryBytes, relativePath: "inputs/selected.lib", kind: .technology, format: .liberty)
        let report = try await store.registerInput(source("selection-report.json"), relativePath: "inputs/selection-report.json", kind: .technology, format: .json)
        let raw = try await store.registerInput(source("original-technology.raw"), relativePath: "inputs/original-technology.raw", kind: .technology, format: .raw)
        let calibration = try await store.registerInput(Data("Analytical test law only; not Sky130 calibration or process qualification.".utf8),
            relativePath: "inputs/analytical-assumption.txt", kind: .technology, format: .raw)
        let range = PEXDimensionRangeMeters(minimumMeters: 1e-12, maximumMeters: 1)
        let electrical = PEXElectricalModel(law: .analyticalRectilinearV1, coplanarScreening: nil, processName: Self.process, cornerID: "analytical", temperatureKelvin: 298.15,
            voltageVolts: 1.8, parameters: [:], referenceNodeName: "0", calibrationArtifacts: [calibration.reference.id],
            conductors: [("LI", 0.0), ("M1", 2e-6)].map { .init(layerName: $0.0, bottomHeightMeters: $0.1, thicknessMeters: 1e-6,
                resistivityOhmMeters: 1e-5, groundAreaFaradsPerSquareMeter: 1e-4, groundPerimeterFaradsPerMeter: 1e-11, widthRange: range, lengthRange: range) },
            vias: [.init(viaName: "L1M1_PR", cutLayerName: "MC", bottomLayerName: "LI", topLayerName: "M1", resistanceOhmsPerCut: 1,
                cutWidthRange: range, cutHeightRange: range)], couplings: [("LI", "LI"), ("LI", "M1"), ("M1", "M1")].map {
                .init(firstLayerName: $0.0, secondLayerName: $0.1, areaFaradsPerSquareMeter: 1e-6, sidewallFarads: 1e-18, gapRange: range) })
        let rc = TechnologyIR(processName: Self.process, stack: [("LI", 0), ("MC", 1), ("M1", 2)].map { .init(name: $0.0, order: $0.1) },
            logicalToPhysicalLayerMap: ["li1": "LI", "mcon": "MC", "met1": "M1"], vias: [.init(name: "L1M1_PR", topLayer: "M1", bottomLayer: "LI")],
            defaultExtractionRules: .default, backendHints: [:], electricalModels: [electrical])
        try electrical.validate(in: rc)
        let rcBinding = try await store.registerInput(try PhysicalDesignJSONCodec().encode(rc), relativePath: "inputs/analytical-rc.json", kind: .technology, format: .json)
        let layers: [PDKLayerDefinition] = [.init(layerID: "li1", name: "li1", number: 1, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "met1", name: "met1", number: 2, purpose: .metal, isRoutingLayer: true),
            .init(layerID: "mcon", name: "mcon", number: 3, purpose: .via),
            .init(layerID: "nwell", name: "nwell", number: 4, purpose: .well), .init(layerID: "pwell", name: "pwell", number: 5, purpose: .well)]
        let parsedLibrary = try LibertyParser().parse(libraryBytes)
        let devices = try [Self.buffer, Self.inverter, Self.flipFlop].map { name in
            let cell = try #require(parsedLibrary.cells[name])
            return PDKDeviceDefinition(deviceID: name, modelName: name, terminals: try cell.pins.enumerated().map { index, pin in
                try #require(pin.direction == .input || pin.direction == .output)
                return .init(name: pin.name, role: pin.isClock ? .clock : pin.direction == .input ? .input : .output, order: index)
            })
        }
        try #require(Set(devices.map(\.deviceID)) == Set([Self.buffer, Self.inverter, Self.flipFlop]))
        let manifest = PDKManifest(processID: Self.process, version: "selected-source-v1", assets: [
            ("tech", PDKAssetRole.technology, technology), ("cells", .cell, cellSource), ("liberty", .liberty, liberty), ("rc", .extraction, rcBinding)
        ].map { id, role, binding in
            .init(assetID: id, role: role, path: binding.path, kind: binding.descriptor.kind, format: binding.descriptor.format,
                sha256: binding.reference.digest.hexadecimalValue, byteCount: Int64(binding.reference.byteCount),
                cornerIDs: role == .liberty ? ["tt"] : [])
        }, layers: layers, devices: devices, corners: [.init(cornerID: "tt", pvt: .init(process: .init(name: "typical", nominal: true), voltage: 1.8, temperatureCelsius: 25),
            rcCorner: "analytical", assetIDs: ["liberty", "rc", "tech"], viewMappings: ["liberty": "liberty"])], crossViewMappings: [
                .init(mappingID: "tech", view: .lef, assetID: "tech", layerIDs: layers.map(\.layerID)),
                .init(mappingID: "cells", view: .lef, assetID: "cells", physicalNames: [Self.buffer, Self.inverter, Self.flipFlop], layerIDs: layers.map(\.layerID), deviceIDs: devices.map(\.deviceID)),
                .init(mappingID: "timing", view: .liberty, assetID: "liberty", deviceIDs: devices.map(\.deviceID), cornerIDs: ["tt"])])
        try #require(manifest.validate().isValid, "\(manifest.validate().findings)")
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/process.json", kind: .technology, format: .json)
        let timingLibrary = try await retainTimingInput(liberty, store: store, root: root)
        let timingManifest = try await retainTimingInput(pdk, store: store, root: root)
        let library = try LogicArtifactBinding.local(reference: liberty.reference,
            fileURL: root.appending(path: liberty.path))
        try #require(library.reference == timingLibrary.reference)
        let operatingScope = LogicOperatingProcessScope(libraries: [.init(artifact: timingLibrary, cornerIDs: ["tt"])],
            pdkManifest: timingManifest, processID: Self.process, pdkVersion: manifest.version,
            cornerIDs: ["tt"], characterizationBindings: Self.tt)
        let logic = NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
        let synthesized = try await logic.execute(.init(runID: "checked-source", sources: [.init(logicalName: "top.sv", artifact: sourceBinding)],
            roots: ["top.sv"], top: "top", library: library, limits: runtimeLimits,
            realizationPolicy: .physicalCells,
            operatingConditionPolicies: [Self.buffer, Self.inverter, Self.flipFlop].map {
                .init(library: library.reference, cell: $0, cornerID: "tt", conditions: Self.pg)
            }, operatingProcessScope: operatingScope))
        let verified = try await logic.load(synthesized.receipt, limits: runtimeLimits)
        try #require(verified.request.constraints.timing == nil)
        try #require(verified.request.operatingProcessScope == operatingScope)
        var checkedDevices: [PDKDeviceDefinition] = []
        verified.mapped.library.withCells { cells in
            for cellIndex in 0..<cells.count {
                let cell = cells[cellIndex]
                var terminals: [PDKDeviceTerminal] = []
                cell.withPins { pins in
                    for pinIndex in 0..<pins.count {
                        let pin = pins[pinIndex]
                        var role: PDKTerminalRole = switch pin.direction {
                        case .input: .input
                        case .output: .output
                        }
                        if let state = cell.state, case .flipFlop(let clock, _) = state.control,
                            clock.rawValue == pinIndex { role = .clock }
                        terminals.append(.init(name: pin.name, role: role, order: pinIndex))
                    }
                }
                checkedDevices.append(.init(deviceID: cell.name, modelName: cell.name, terminals: terminals))
            }
        }
        try #require(checkedDevices == devices, "Early source inventory must equal the checked functional pin tables")
        let actualNetlist = try FileSystemLogicArtifactStore(rootDirectory: root).read(synthesized.payload.netlist)
        let design = try await store.registerInput(actualNetlist, relativePath: "inputs/mapped.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("create_clock -name c -period 10 [get_ports c]".utf8), relativePath: "inputs/clock.sdc", kind: .constraint, format: .sdc)
        var request = PhysicalDesignRequest(runID: "actual-native-cts", inputBindings: [pdk, liberty, report, raw, design, constraints],
            design: .init(artifact: design.reference, topDesignName: "top", designDigest: design.reference.digest.hexadecimalValue), constraints: constraints,
            requestedModeIDs: ["functional"], pdk: try .init(manifest: pdk.reference,
                manifestLocator: .init(location: ArtifactLocation(workspaceRelativePath: pdk.path), role: .input, kind: .technology, format: .json), processID: Self.process, version: manifest.version),
            stage: .clockTreeSynthesis, configuration: .init(placementSpacing: 0, preferredRoutingLayers: [1, 2], maximumRoutingLayer: 2,
                implementationConstraints: .init(clockBufferMaster: Self.buffer, clockRouteLayer: 2, routeWidth: 170, routeSpacing: 140,
                    sourceRoutingWidthPolicy: .sourceDefault)),
            executionIntent: .characterizedTiming, processAssets: ["tech": technology, "cells": cellSource])
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        var snapshot = PhysicalDesignSnapshot(topCell: "top", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 18400, height: 8160), core: .init(x: 0, y: 0, width: 18400, height: 8160),
            rows: [0, 2720, 5440].map { .init(id: "row-\($0)", originX: 0, originY: Int64($0), siteWidth: 460, height: 2720, siteCount: 40, siteName: "unithd") },
            implementationState: .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 170, spacing: 340, count: 24),
                .init(id: "V", layer: 1, direction: "vertical", origin: 230, spacing: 460, count: 40)]))
        var instanceIDs: [DesignEntityID: String] = [:], netIDs: [DesignEntityID: String] = [:]
        var portIDs: [DesignEntityID: [String]] = [:], stateIDs: [DesignEntityID: String] = [:]
        var clockSource = "", clockNet = "", clockSinks: [String] = [], ffOrdinal = 0
        try verified.mapped.withTables { nets, instances, connections, ports, bits, _ in
            var members = [[String]](repeating: [], count: nets.count)
            for index in instances.indices {
                let instance = instances[index], id = "cell-\(index)"
                let definition = try verified.mapped.library.cell(at: instance.cell), master = try geometry.requireMaster(definition.name)
                let sequential = instance.stateID != nil
                let cell = PhysicalDesignSnapshot.Cell(id: id, master: definition.name, x: sequential ? Int64(ffOrdinal * 8280) : 0,
                    y: sequential ? 2720 : 5440, width: master.width, height: master.height, placed: true, locked: true)
                if sequential { ffOrdinal += 1; stateIDs[try #require(instance.stateID)] = id }
                snapshot.cells.append(cell); instanceIDs[instance.id] = id
                for offset in 0..<definition.pinCount {
                    let pin = try definition.pin(at: .init(offset)), pinID = id + "/" + pin.name
                    let n = connections[instance.pins.lowerBound + offset].rawValue
                    var physical = PhysicalDesignSnapshot.Pin(id: pinID, cellID: id, name: pin.name, netID: "net-\(n)", direction: pin.direction == .input ? "input" : "output")
                    physical = try geometry.referencePin(physical, for: cell)
                    snapshot.pins.append(physical); members[n].append(pinID)
                    if let state = definition.state, offset == state.control.pin.rawValue { clockSinks.append(pinID); clockNet = "net-\(n)" }
                }
            }
            var topPortOrdinal = 0
            for index in ports.indices {
                let port = ports[index]; var physicalPins: [String] = []
                for bit in 0..<port.bits.count {
                    let n = bits[port.bits.lowerBound + bit].rawValue, id = "port-\(index)-\(bit)"
                    let isClock = !derived && "net-\(n)" == clockNet
                    let x: Int64 = isClock ? 16790 : 17710
                    let y: Int64 = isClock ? 1300 : Int64(4000 + topPortOrdinal * 500)
                    topPortOrdinal += 1
                    snapshot.pins.append(.init(id: id, name: id, x: x, y: y, netID: "net-\(n)", direction: port.direction == .input ? "input" : "output", accessLayer: 1,
                        topPort: .init(rectangle: .init(x: 0, y: 0, width: 200, height: 200), layer: 1,
                            placementX: x - 100, placementY: y - 100, orientation: .n, placementStatus: .fixed, use: isClock ? .clock : .signal)))
                    if isClock { clockSource = id }
                    physicalPins.append(id); members[n].append(id)
                }
                portIDs[port.id] = physicalPins
            }
            for index in nets.indices {
                let id = "net-\(index)"; netIDs[nets[index].id] = id
                snapshot.nets.append(.init(id: id, pinIDs: members[index], isClock: id == clockNet))
            }
        }
        if derived { clockSource = try #require(snapshot.pins.first { $0.netID == clockNet && $0.direction == "output" }?.id) }
        snapshot = try geometry.bind(snapshot); try geometry.validate(snapshot)
        let retainedTracks = try #require(snapshot.implementationState?.tracks)
        for pin in snapshot.pins {
            guard let port = pin.topPort else { continue }
            let width = try geometry.routingWidthAndSpacing(layer: port.layer, units: snapshot.unitsPerMicron,
                width: nil, areaHandledSeparately: true).width
            let half = width / 2
            let minimumX = port.placementX + port.rectangle.x
            let minimumY = port.placementY + port.rectangle.y
            let maximumX = minimumX + port.rectangle.width
            let maximumY = minimumY + port.rectangle.height
            let tracks = retainedTracks.filter { $0.layer == port.layer && $0.direction == "vertical" }
            let contained = tracks.contains { track in
                (0..<track.count).contains { ordinal in
                    let x = track.origin + ordinal * track.spacing
                    return x == pin.x && x - half >= minimumX && x + half <= maximumX
                        && pin.y - half >= minimumY && pin.y + half <= maximumY
                }
            }
            try #require(contained, "Actual top PORT \(pin.id) must contain its full source-width on-track wire cap")
        }
        let correspondence = PhysicalLogicECOCorrespondence(instanceIDs: instanceIDs, netIDs: netIDs, portPinIDs: portIDs, stateInstanceIDs: stateIDs)
        var baseline = try context()
        _ = try NativePhysicalLogicConnectivityChecker().check(verified, snapshot: snapshot,
            correspondence: .init(instanceIDs: instanceIDs, portPinIDs: portIDs), limits: limits())
        let originalAssessment = try NativePhysicalLogicECOChecker().check(verified, candidate: snapshot, correspondence: correspondence, limits: limits(), context: &baseline)
        guard case .equivalent = originalAssessment.verdict else { throw PhysicalLogicHandoffError.logicalMismatch("Initial actual source correspondence was not proved") }
        let extraction = NativePEXCalculationLimits(maximumMeshCells: 10_000)
        let electrodes = NativePEXElectrodeLimits(maximumContacts: 10_000)
        let projectionRecords = 100_000, dimension = 1000, newtonIterations = 1_000_000
        let workCeiling = try transientWorkCeiling(extraction: extraction, electrodes: electrodes,
            maximumProjectionRecords: projectionRecords, maximumMatrixDimension: dimension, maximumNewtonIterations: newtonIterations)
        let numerics = PhysicalDesignClockNumerics(stopTimeSeconds: 5e-9, maximumTimeStepSeconds: 5e-11, minimumTimeStepSeconds: 1e-19,
            relativeTolerance: 1e-5, voltageTolerance: 1e-9, currentTolerance: 1e-15, lteTolerance: 1, maximumNewtonIterationsPerSolve: 20,
            maximumStepReductions: 30, maximumRefinements: 4, crossingAgreementSeconds: 1e-11, maximumCellSpanDBU: 2000,
            maximumInputBytes: 2_000_000, maximumProjectionRecords: projectionRecords, maximumGeometryProbes: 1_000_000,
            extraction: extraction, electrodes: electrodes,
            transient: .init(maximumAcceptedSteps: 100_000, maximumSolveAttempts: 300_000, maximumNewtonIterations: newtonIterations,
                maximumSavedScalars: 10_000_000, maximumMatrixDimension: dimension, maximumWorkUnits: workCeiling, maximumBreakpoints: 100),
            captureLimits: try captureProfile())
        let rootPin = try #require(snapshot.pins.first { $0.id == clockSource })
        let model = PhysicalDesignClockTimingModel(processID: Self.process, pdkVersion: manifest.version, cornerID: "tt", rcCornerID: "analytical", libertyAssetID: "liberty", rcAssetID: "rc", rcParameters: [:],
            pdkManifestDigest: pdk.reference.digest.hexadecimalValue, rcModelDigest: rcBinding.reference.digest.hexadecimalValue, cellLibraryDigest: liberty.reference.digest.hexadecimalValue,
            method: .passiveLinearRCTransientV1, quietBoundary: .allOtherConductorsIdealReference,
            clocks: [.init(netID: clockNet, sourcePinID: clockSource, sinkPinIDs: clockSinks, rise: [.init(time: 0, voltage: 0), .init(time: 1e-10, voltage: 1.8)],
                fall: [.init(time: 0, voltage: 1.8), .init(time: 1e-10, voltage: 0)], topology: .bufferEachSink, bufferMaster: Self.buffer,
                bufferRiseShape: [.init(time: 0, voltage: 0), .init(time: 1, voltage: 1)], bufferFallShape: [.init(time: 0, voltage: 1), .init(time: 1, voltage: 0)])],
            electrodes: [.init(master: Self.flipFlop, pin: "CLK", faces: [.init(side: .minX, coordinate: 90, begin: 1100, end: 1500)]),
                .init(master: Self.buffer, pin: "A", faces: [.init(side: .minX, coordinate: 105, begin: 1000, end: 1300)]),
                .init(master: Self.buffer, pin: "X", faces: [.init(side: .maxX, coordinate: 1295, begin: 1800, end: 2200)]),
                .init(master: Self.inverter, pin: "Y", faces: [.init(side: .maxX, coordinate: 1050, begin: 1800, end: 2200)])],
            constraints: .init(maximumLatencySeconds: 4e-9, maximumSkewSeconds: 2e-9, maximumSlewSeconds: 4e-9, maximumLoadFarads: 1e-12), numerics: numerics,
            topPortElectrodes: derived ? [] : [.init(pinID: clockSource, faces: [.init(side: .maxX, coordinate: Int32(rootPin.x + 100), begin: Int32(rootPin.y - 50), end: Int32(rootPin.y + 50))])])
        let modelBinding = try await store.registerInput(try PhysicalDesignJSONCodec().encode(model), relativePath: "inputs/clock-model.json", kind: .technology, format: .json)
        let reference = PhysicalDesignClockTimingModelReference(modelArtifact: modelBinding, pdkManifestArtifact: pdk, rcModelArtifact: rcBinding, cellLibraryArtifact: liberty,
            calibrationArtifacts: [calibration], processID: Self.process, pdkVersion: manifest.version, cornerID: "tt")
        request.initialSnapshot = snapshot; request.clockTimingModel = reference
        for binding in [modelBinding] + reference.sourceArtifacts {
            if !request.inputBindings.contains(binding) { request.inputBindings.append(binding) }
            if !request.inputs.contains(binding.reference) { request.inputs.append(binding.reference) }
        }
        retained = true
        return .init(root: root, synthesis: verified, request: request, store: store, geometry: geometry, correspondence: correspondence, model: model, reference: reference)
    }

    private func correspondence(_ fixture: Fixture, candidate: PhysicalDesignSnapshot) throws -> PhysicalLogicECOCorrespondence {
        var instances = fixture.correspondence.instanceIDs, nets = fixture.correspondence.netIDs
        for (index, cell) in candidate.cells.enumerated() where !instances.values.contains(cell.id) {
            instances[try .init(rawValue: UInt64.max - UInt64(index))] = cell.id
        }
        for (index, net) in candidate.nets.enumerated() where !nets.values.contains(net.id) {
            nets[try .init(rawValue: UInt64.max - 10_000 - UInt64(index))] = net.id
        }
        return .init(instanceIDs: instances, netIDs: nets, portPinIDs: fixture.correspondence.portPinIDs, stateInstanceIDs: fixture.correspondence.stateInstanceIDs)
    }

    private func verifySavedRouting(_ bytes: Data, candidate: PhysicalDesignSnapshot,
                                    geometry: PhysicalDesignProcessGeometry) throws {
        let allSegments = candidate.routes.flatMap(\.segments)
        try #require(!allSegments.isEmpty)
        for segment in allSegments {
            let expected = try geometry.routingWidthAndSpacing(layer: segment.layer, units: candidate.unitsPerMicron,
                width: nil, areaHandledSeparately: true).width
            #expect(segment.layer == 1 || segment.layer == 2)
            #expect(segment.widthDBU == expected)
            #expect(expected == (segment.layer == 1 ? 170 : 140))
        }
        let document = try DEFLibraryReader.read(bytes)
        #expect(document.designName == candidate.topCell && document.dbuPerMicron == Double(candidate.unitsPerMicron))
        #expect(Set(document.nets.map(\.name)) == Set(candidate.nets.map(\.id)))
        for net in document.nets {
            var remaining = candidate.routes.filter { $0.netID == net.name }.flatMap(\.segments)
            var contacts = candidate.vias.filter { $0.netID == net.name }
            for route in net.routing {
                let layer = try #require(geometry.layers.first { $0.value.name == route.layerName }?.key)
                if let master = route.viaName {
                    try #require(route.points.count == 1)
                    let point = route.points[0]
                    let index = try #require(contacts.firstIndex { $0.master == master && $0.x == Int64(point.x) && $0.y == Int64(point.y) && $0.lowerLayer == Int(layer) })
                    contacts.remove(at: index)
                } else {
                    try #require(route.points.count == 2 && route.pointExtensions.count == 2)
                    let width = try geometry.routingWidthAndSpacing(layer: Int(layer), units: candidate.unitsPerMicron,
                        width: nil, areaHandledSeparately: true).width
                    let a = route.points[0], b = route.points[1]
                    let decoded = PhysicalDesignSnapshot.RouteSegment(id: "standard-readback", layer: Int(layer),
                        x1: Int64(a.x), y1: Int64(a.y), x2: Int64(b.x), y2: Int64(b.y), widthDBU: width,
                        endpointExtensions: .init(beginDBU: Int64(try #require(route.pointExtensions[0])), endDBU: Int64(try #require(route.pointExtensions[1]))))
                    let rectangle = try decoded.qualifiedFootprint()
                    let index = try #require(try remaining.firstIndex { segment in
                        guard segment.layer == Int(layer) else { return false }
                        return try segment.qualifiedFootprint() == rectangle
                    })
                    remaining.remove(at: index)
                }
            }
            #expect(remaining.isEmpty && contacts.isEmpty)
        }
    }

    @Test("actual primary and derived clocks execute Native CTS and independently recheck the real candidate", arguments: [false, true])
    func actualNativeCTS(derived: Bool) async throws {
        let fixture = try await fixture(derived: derived); defer { cleanup(fixture.root) }
        let retainedModel = try PhysicalDesignJSONCodec().decode(PhysicalDesignClockTimingModel.self,
            from: await fixture.store.read(fixture.reference.modelArtifact))
        #expect(retainedModel.numerics.minimumTimeStepSeconds == 1e-19)
        if !derived {
            let report = try JSONDecoder().decode(SelectionReport.self, from: source("selection-report.json"))
            for input in report.sources {
                let bytes = try source(input.selectedFile)
                #expect(bytes.count == input.selectedByteCount)
                #expect(try SHA256ContentDigester().digest(data: bytes, using: .sha256).hexadecimalValue == input.selectedSHA256)
                if input.selectedFile == "technology.lef" {
                    #expect(try SHA256ContentDigester().digest(data: source("original-technology.raw"), using: .sha256).hexadecimalValue == input.originSHA256)
                    let text = String(decoding: bytes, as: UTF8.self)
                    #expect(text.contains("MINENCLOSEDAREA") && text.contains("ENCLOSURE ABOVE") && text.contains("AREA 0.0561"))
                }
            }
            #expect(String(decoding: try source("cells.lef"), as: UTF8.self).contains("PIN VNB"))
        }
        let result = try await NativePhysicalDesignExecutor(expectedStage: .clockTreeSynthesis, artifactStore: fixture.store).execute(fixture.request)
        try #require(result.status == .completed, "\(result.diagnostics)")
        let binding = try #require(result.payload.physicalDesign?.layoutArtifact)
        let candidate = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await fixture.store.read(binding))
        try verifySavedRouting(await fixture.store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })),
            candidate: candidate, geometry: fixture.geometry)
        let tree = try #require(candidate.clockTrees.first)
        #expect(tree.timingEstimate?.modelDigest == fixture.reference.modelArtifact.reference.digest.hexadecimalValue)
        #expect(tree.bufferCellIDs.count == 2 && Set(candidate.cells.filter(\.isClockBuffer).map(\.master)) == [Self.buffer])
        #expect(candidate.cells.count == fixture.synthesis.mapped.instanceCount + 2)
        #expect(tree.sinkPinIDs.count == 2 && tree.timingEstimate?.observations?.constraintsSatisfied == true)
        #expect(result.payload.claims.production == .blocked && result.payload.claims.timing == .blocked)
        for artifact in result.artifactBindings { _ = try await fixture.store.read(artifact) }
        let map = try correspondence(fixture, candidate: candidate); var run = try context()
        let checked = try NativePhysicalLogicECOChecker().check(fixture.synthesis, candidate: candidate, correspondence: map, limits: limits(), context: &run)
        guard case .equivalent(let proof) = checked.verdict else { Issue.record("Actual Native CTS candidate was not proved"); return }
        #expect(proof.kind == .statePreservingInduction)
        try proof.requireBinding(to: checked.problem); try checked.requireBinding(to: candidate)
        let replayed = try NativeLogicEquivalenceChecker().recheck(checked.problem, certificate: proof.proof.certificate, context: &run)
        try replayed.requireBinding(to: checked.problem)
        try await requireSavedSTABinding(checked, fixture: fixture, name: "api")
        checked.mapped.withStateClocks { clocks in
            #expect(clocks.count == 2 && clocks[0].carrier != clocks[1].carrier)
            for index in clocks.indices {
                guard case .primaryInput(_, let inverted, let rising) = clocks[index].lineage else { Issue.record("Physical CTS lost primary root lineage"); continue }
                #expect(inverted == derived && rising == !derived)
            }
        }
        var changed = candidate
        let input = try #require(changed.pins.firstIndex { tree.bufferCellIDs.contains($0.cellID ?? "") && $0.name == "A" })
        let oldNet = try #require(changed.pins[input].netID)
        let dataNet = try #require(changed.pins.first { $0.cellID == nil && $0.direction == "input" && $0.netID != oldNet }?.netID)
        changed.pins[input].netID = dataNet
        for index in changed.nets.indices {
            if changed.nets[index].id == oldNet { changed.nets[index].pinIDs.removeAll { $0 == changed.pins[input].id } }
            if changed.nets[index].id == dataNet { changed.nets[index].pinIDs.append(changed.pins[input].id) }
        }
        #expect(throws: PhysicalLogicHandoffError.self) { try checked.requireBinding(to: changed) }
        #expect(throws: PhysicalLogicHandoffError.self) {
            try NativePhysicalLogicECOChecker().check(fixture.synthesis, candidate: changed, correspondence: map, limits: limits(), context: &run)
        }
        var inverted = candidate
        for index in inverted.cells.indices where tree.bufferCellIDs.contains(inverted.cells[index].id) { inverted.cells[index].master = Self.inverter }
        for index in inverted.pins.indices where tree.bufferCellIDs.contains(inverted.pins[index].cellID ?? "") && inverted.pins[index].name == "X" { inverted.pins[index].name = "Y" }
        #expect(throws: PhysicalLogicHandoffError.self) {
            try NativePhysicalLogicECOChecker().check(fixture.synthesis, candidate: inverted, correspondence: map, limits: limits(), context: &run)
        }
    }
    private func changedRequest(_ fixture: Fixture, model: PhysicalDesignClockTimingModel, name: String,
                                snapshot: PhysicalDesignSnapshot? = nil) async throws -> PhysicalDesignRequest {
        let binding = try await fixture.store.registerInput(try PhysicalDesignJSONCodec().encode(model),
            relativePath: "inputs/" + name + ".json", kind: .technology, format: .json)
        var request = fixture.request, reference = fixture.reference
        reference.modelArtifact = binding; request.clockTimingModel = reference
        request.runID = name; request.initialSnapshot = snapshot ?? request.initialSnapshot
        request.inputBindings.append(binding); request.inputs.append(binding.reference)
        return request
    }

    @Test("missing, foreign, uncovered, ambiguous and distributed primary source facts cannot publish CTS")
    func invalidPrimaryAndElectrodeProfiles() async throws {
        let fixture = try await fixture(); defer { cleanup(fixture.root) }
        let engine = NativePhysicalDesignExecutor(expectedStage: .clockTreeSynthesis, artifactStore: fixture.store)
        for reason in ["legacyPrimary", "missingTable", "missingBinding", "foreignBinding", "duplicateBinding", "uncoveredFace", "internalFace", "distributedFaces", "multipleDrivers", "wellSource", "budget", "callerSpacing190", "topPortGap50", "uniformWidth170"] {
            var model = fixture.model, snapshot = try #require(fixture.request.initialSnapshot)
            let root = try #require(snapshot.pins.firstIndex { $0.id == model.clocks[0].sourcePinID })
            switch reason {
            case "legacyPrimary": model.schemaVersion = 2; model.topPortElectrodes = nil; model.numerics.captureLimits = nil
            case "missingTable": model.topPortElectrodes = nil
            case "missingBinding": model.topPortElectrodes = []
            case "foreignBinding": model.topPortElectrodes?[0].pinID = "foreign-root"
            case "duplicateBinding":
                let duplicate = try #require(model.topPortElectrodes?.first)
                model.topPortElectrodes?.append(duplicate)
            case "uncoveredFace", "internalFace":
                let face = try #require(model.topPortElectrodes?.first?.faces.first)
                model.topPortElectrodes?[0].faces[0] = .init(side: face.side,
                    coordinate: face.coordinate + (reason == "uncoveredFace" ? 5 : -100), begin: face.begin, end: face.end)
            case "distributedFaces":
                model.electrodes[2].faces.append(.init(side: .maxX, coordinate: 1295, begin: 900, end: 1200))
            case "multipleDrivers":
                var pin = snapshot.pins[root]; pin.id = "second-external-clock-driver"; pin.name = pin.id
                snapshot.pins.append(pin)
                let net = try #require(snapshot.nets.firstIndex { $0.id == model.clocks[0].netID })
                snapshot.nets[net].pinIDs.append(pin.id); model.clocks[0].sinkPinIDs.append(pin.id)
            case "wellSource":
                let port = try #require(snapshot.pins[root].topPort)
                snapshot.pins[root].accessLayer = 4
                snapshot.pins[root].topPort = .init(rectangle: port.rectangle, layer: 4, placementX: port.placementX,
                    placementY: port.placementY, orientation: port.orientation, placementStatus: port.placementStatus, use: port.use)
            case "callerSpacing190", "uniformWidth170": break
            case "topPortGap50":
                try fixture.synthesis.mapped.withTables { _, _, _, ports, _, _ in
                    for portIndex in ports.indices {
                        let ids = try #require(fixture.correspondence.portPinIDs[ports[portIndex].id])
                        for bitIndex in ids.indices where ids[bitIndex] != model.clocks[0].sourcePinID {
                            let pinIndex = try #require(snapshot.pins.firstIndex { $0.id == ids[bitIndex] })
                            let port = try #require(snapshot.pins[pinIndex].topPort)
                            let y = Int64(4000 + portIndex * 700 + bitIndex * 250)
                            snapshot.pins[pinIndex].y = y
                            snapshot.pins[pinIndex].topPort = .init(rectangle: port.rectangle, layer: port.layer,
                                placementX: port.placementX, placementY: y - 100, orientation: port.orientation,
                                placementStatus: port.placementStatus, use: port.use)
                        }
                    }
                }
            default: model.numerics.maximumProjectionRecords = 1
            }
            var request = try await changedRequest(fixture, model: model, name: reason, snapshot: snapshot)
            if reason == "callerSpacing190" {
                var constraints = try #require(request.configuration.implementationConstraints)
                constraints.routeSpacing = 190
                request.configuration.implementationConstraints = constraints
            }
            if reason == "uniformWidth170" {
                var constraints = try #require(request.configuration.implementationConstraints)
                constraints.sourceRoutingWidthPolicy = .uniform
                request.configuration.implementationConstraints = constraints
            }
            let result = try await engine.execute(request)
            #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil,
                "\(reason): \(result.diagnostics)")
            let expectedDiagnostic = switch reason {
            case "legacyPrimary": "explicit primary clock PORT/source profile"
            case "missingTable": "clock schema or legacy top-port electrode data"
            case "missingBinding", "foreignBinding": "exact primary clock electrode coverage"
            case "duplicateBinding": "top-port electrode identity or faces"
            case "uncoveredFace", "internalFace": "uncoveredFace"
            case "distributedFaces": "unique actual PORT"
            case "multipleDrivers": "sole clock source/net identity"
            case "wellSource": "declared mapped source ROUTING layer"
            case "callerSpacing190", "topPortGap50": "routing_final_spacing_invalid"
            case "uniformWidth170": "routing_width_unsupported"
            default: "clock/source/electrode identity or input budget"
            }
            #expect(result.diagnostics.contains { $0.summary.contains(expectedDiagnostic) },
                "\(reason): \(result.diagnostics)")
        }
    }

    @Test("disconnected or ambiguous actual PORT pieces cannot be idealized into a clock source", arguments: [false, true])
    func disconnectedActualPORTIsRejected(ambiguous: Bool) async throws {
        let fixture = try await fixture(disconnected: !ambiguous, ambiguous: ambiguous); defer { cleanup(fixture.root) }
        let result = try await NativePhysicalDesignExecutor(expectedStage: .clockTreeSynthesis, artifactStore: fixture.store).execute(fixture.request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty)
        #expect(result.diagnostics.contains { $0.summary.contains("disconnected") || $0.summary.contains("open") || $0.summary.contains("unique actual PORT") }, "\(result.diagnostics)")
    }

    @Test("legacy cell-root schema 2 retains its exact version and actual CTS behavior")
    func legacyCellRootRemainsSupported() async throws {
        let fixture = try await fixture(derived: true); defer { cleanup(fixture.root) }
        var model = fixture.model; model.schemaVersion = 2; model.topPortElectrodes = nil
        let profile = try #require(model.numerics.captureLimits)
        model.numerics.captureLimits = nil
        model.numerics.maximumProjectionRecords = max(model.numerics.maximumProjectionRecords, profile.maximumDecompositionInputEntries)
        model.numerics.maximumGeometryProbes = max(model.numerics.maximumGeometryProbes, profile.maximumContactProbes)
        let request = try await changedRequest(fixture, model: model, name: "legacy-cell-root")
        let reference = try #require(request.clockTimingModel)
        let admitted = try await LocalPhysicalDesignClockTimingModelLoader().load(reference,
            for: try #require(request.initialSnapshot), from: fixture.store)
        #expect(admitted.model.schemaVersion == 2 && admitted.model.topPortElectrodes == nil && admitted.model.numerics.captureLimits == nil)
        #expect(admitted.reference.modelArtifact.reference == reference.modelArtifact.reference)
        let result = try await NativePhysicalDesignExecutor(expectedStage: .clockTreeSynthesis, artifactStore: fixture.store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let candidate = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
            from: await fixture.store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        #expect(candidate.clockTrees.first?.timingEstimate?.modelDigest == reference.modelArtifact.reference.digest.hexadecimalValue)
        var run = try context()
        let assessment = try NativePhysicalLogicECOChecker().check(fixture.synthesis, candidate: candidate,
            correspondence: correspondence(fixture, candidate: candidate), limits: limits(), context: &run)
        guard case .equivalent(let proof) = assessment.verdict else { Issue.record("Legacy actual CTS lost its functional proof"); return }
        try proof.requireBinding(to: assessment.problem)
    }

    private func executeCLI(_ request: PhysicalDesignRequest, fixture: Fixture, name: String) async throws -> (Int32, PhysicalDesignResult) {
        for binding in request.inputBindings {
            let destination = fixture.root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fixture.store.read(binding).write(to: destination)
        }
        let requestURL = fixture.root.appending(path: "\(name)-request.json")
        try PhysicalDesignJSONCodec().encode(request).write(to: requestURL)
        let binary: URL
        if let path = ProcessInfo.processInfo.environment["PHYSICAL_DESIGN_CLI"] {
            binary = URL(fileURLWithPath: path)
        } else {
            var directory = Bundle.module.bundleURL, executable: URL?
            for _ in 0..<4 {
                directory.deleteLastPathComponent()
                let candidate = directory.appending(path: "physical-design")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            }
            binary = try #require(executable, "Build the physical-design product or bind it with PHYSICAL_DESIGN_CLI")
        }
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "The bound CLI is not executable")
        let resultURL = fixture.root.appending(path: "\(name)-result.json"), errorURL = fixture.root.appending(path: "\(name)-stderr.txt")
        try Data().write(to: resultURL); try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: resultURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { do { try output.close(); try errors.close() } catch { Issue.record(error) } }
        let process = Process(); process.executableURL = binary
        process.arguments = ["--request", requestURL.path, "--project-root", fixture.root.path]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            throw CocoaError(.executableRuntimeMismatch)
        }
        let result = try PhysicalDesignJSONCodec().decode(PhysicalDesignResult.self, from: Data(contentsOf: resultURL))
        return (process.terminationStatus, result)
    }

    @Test("explicit capture quotas refuse through API and CLI without candidate publication", arguments: [false, true])
    func explicitCaptureBudgetsRejectAPIAndCLI(contact: Bool) async throws {
        let fixture = try await fixture(); defer { cleanup(fixture.root) }
        var model = fixture.model
        var profile = try #require(model.numerics.captureLimits)
        if contact { profile.maximumContactProbes = 1 }
        else { profile.maximumDecompositionInputEntries = 1 }
        model.numerics.captureLimits = profile
        let name = contact ? "explicit-contact-quota" : "explicit-entry-quota"
        let request = try await changedRequest(fixture, model: model, name: name)
        let api = try await NativePhysicalDesignExecutor(expectedStage: .clockTreeSynthesis, artifactStore: fixture.store).execute(request)
        let (status, cli) = try await executeCLI(request, fixture: fixture, name: name)
        #expect(status != 0)
        for result in [api, cli] {
            #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil,
                "\(result.diagnostics)")
            #expect(result.diagnostics.contains { $0.summary.contains(contact ? "contactProbes" : "inputEntries") },
                "\(result.diagnostics)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "runs/\(request.runID)").path))
    }

    @Test("Built CLI saves the actual primary CTS candidate before independent functional recheck")
    func actualNativeCTSCLIPrimary() async throws {
        try await actualNativeCTSCLI(derived: false)
    }

    @Test("Built CLI saves the actual derived CTS candidate before independent functional recheck")
    func actualNativeCTSCLIDerived() async throws {
        try await actualNativeCTSCLI(derived: true)
    }

    private struct ConductorFootprint: Hashable {
        let net: String
        let layer: Int
        let x: Int64
        let y: Int64
        let width: Int64
        let height: Int64
    }

    private func actualNativeCTSCLI(derived: Bool) async throws {
        let fixture = try await fixture(derived: derived); defer { cleanup(fixture.root) }
        var request = fixture.request
        if !derived {
            var initial = try #require(fixture.request.initialSnapshot)
            let root = try #require(initial.pins.firstIndex { $0.id == fixture.model.clocks[0].sourcePinID })
            let port = try #require(initial.pins[root].topPort)
            initial.pins[root].topPort = .init(rectangle: port.rectangle, layer: port.layer, placementX: port.placementX,
                placementY: port.placementY, orientation: port.orientation, placementStatus: port.placementStatus, use: .signal)
            request.initialSnapshot = initial
        }
        let (status, result) = try await executeCLI(request, fixture: fixture, name: "actual-cts")
        try #require(status == 0 && result.status == .completed, "\(result.diagnostics)")
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: fixture.root)
        let candidate = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
            from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        #expect(candidate.clockTrees.first?.bufferCellIDs.count == 2)
        var footprints: Set<ConductorFootprint> = []
        for route in candidate.routes {
            for segment in route.segments {
                let rectangle = try segment.qualifiedFootprint()
                let key = ConductorFootprint(net: route.netID, layer: segment.layer, x: rectangle.x,
                    y: rectangle.y, width: rectangle.width, height: rectangle.height)
                try #require(footprints.insert(key).inserted,
                    "Published CTS candidate repeats an exact conductor on net \(route.netID), layer \(segment.layer)")
            }
        }
        try verifySavedRouting(await store.read(try #require(result.artifactBindings.first { $0.descriptor.format == .def })),
            candidate: candidate, geometry: fixture.geometry)
        if !derived {
            #expect(candidate.pins.first { $0.id == fixture.model.clocks[0].sourcePinID }?.topPort?.use == .signal)
        }
        for binding in result.artifactBindings { _ = try await store.read(binding) }
        var run = try context()
        let assessment = try NativePhysicalLogicECOChecker().check(fixture.synthesis, candidate: candidate,
            correspondence: correspondence(fixture, candidate: candidate), limits: limits(), context: &run)
        guard case .equivalent(let proof) = assessment.verdict else { Issue.record("Saved actual CLI CTS candidate was not proved"); return }
        try proof.requireBinding(to: assessment.problem); try assessment.requireBinding(to: candidate)
        let independent = try NativeLogicEquivalenceChecker().recheck(assessment.problem, certificate: proof.proof.certificate, context: &run)
        try independent.requireBinding(to: assessment.problem)
        try await requireSavedSTABinding(assessment, fixture: fixture, name: "cli")
        print("NATIVE_CTS_CLI_ACTUAL_CELL_PROOF_OK producer=\(result.provenance.producer.version) instances=\(candidate.cells.count)")
    }

}
