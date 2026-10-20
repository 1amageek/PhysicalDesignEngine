import Foundation
import Synchronization
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpice
import CoreSpiceIO
import LogicEngineCore
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PhysicalDesignCore
import PhysicalDesignLogicHandoff
import PEXCore
import PEXParsers
import STAEngine
import TimingCore
import OSDIContracts
import OSDIRuntime
import Testing

/// An analytic RC cell, proved as an identity ECO before its electrical source is consumed.
/// This fixture is deliberately distinct from the retained 56-MOS Sky130 preparation evidence.
struct WholeCandidateFlowFixture {
    enum Failure: Error { case missing(String); case mismatch(String); case cleanup(primary: any Error, secondary: any Error) }
    struct Control: LogicRunControlling {
        let cancelled: Bool
        func checkpoint() throws(LogicKernelError) { if cancelled { throw .cancelled } }
    }
    static func context(cancelled: Bool = false) throws -> LogicKernelContext {
        .init(limits: try .init(maximums: Dictionary(uniqueKeysWithValues:
            LogicResource.allCases.map { ($0, UInt64(2_000_000_000)) })), control: Control(cancelled: cancelled))
    }
    static func handoffLimits() throws -> PhysicalLogicHandoffLimits {
        try .init(maximumInstances: 16, maximumPins: 64, maximumNets: 64)
    }
    static func ce(_ lower: Double, _ upper: Double) throws -> CompensatedEnclosure {
        try .init(center: .init(high: lower / 2 + upper / 2), radius: (upper - lower) / 2)
    }
    static func contains(_ value: CompensatedEnclosure, _ point: Double,
        sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let b = value.center.bounds
        #expect((b.lower - value.radius).nextDown <= point && point <= (b.upper + value.radius).nextUp,
            sourceLocation: sourceLocation)
    }
    static let numerical = TransientExecutionLimits(maximumAcceptedSteps: 100,
        maximumSolveAttempts: 100, maximumNewtonIterations: 1000, maximumSavedScalars: 10000,
        maximumMatrixDimension: 64, maximumWorkUnits: 100_000_000, maximumBreakpoints: 100)
    static func resolutionLimits() throws -> MOSResolutionLimits {
        try .init(maximumRetainedBytes: 16_777_216, maximumDiagnosticBytes: 65_536,
            maximumScopeDepth: 16, maximumSymbols: 1024, maximumScopes: 128,
            maximumInvocations: 128, maximumInvocationBindings: 1024, maximumDeclarations: 128,
            maximumPrograms: 2048, maximumBindings: 2048, maximumFunctions: 128,
            maximumFunctionDepth: 16, maximumExpressionNodes: 4096, maximumExpressionDepth: 128,
            maximumCandidates: 128, maximumCacheEntries: 4096, maximumEvaluationSteps: 1_000_000)
    }
    static var flowLimits: NativePrescribedVoltageFlowLimits {
        let c = NativePrescribedVoltageFlowLimits.Capacity(maximumRetainedBytes: 8_388_608,
            maximumWorkspaceBytes: 8_388_608)
        return .init(maximumNativeTerms: 512, maximumTriplets: 1024,
            maximumPreconditionerNonzeros: 1024, maximumIntegerBits: 4096, precisionBits: 192,
            values: c, reduction: c, chart: c, exact: c, root: c, evolution: c,
            result: .init(maximumRetainedBytes: 8_388_608, maximumWorkspaceBytes: 8_388_608))
    }
    static func limits(sourceBytes: UInt64 = 1_048_576, joinBytes: UInt64 = 16_777_216) throws -> PhysicalLogicWholeCandidateFlowLimits {
        .init(handoff: try handoffLimits(), native: .init(maximumDeviceCount: 128,
            maximumMatrixDimension: 64, maximumAllocationBytes: 268_435_456), flow: flowLimits,
            observations: .init(maximumPairCount: 64, maximumRetainedBytes: 1_048_576,
                maximumWorkspaceBytes: 1_048_576), maximumSourceBytes: sourceBytes,
            maximumSPEFBytes: 1_048_576, maximumComposedBytes: 2_097_152,
            maximumJoinBytes: joinBytes, maximumAssociations: 128)
    }
    static let liberty = """
    library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
      operating_conditions(nom){process:1;voltage:1;temperature:25;}
      lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;
        index_1("0,10");index_2("0,10000000000000");}
      cell(BUF){area:1;pg_pin(VPWR){pg_type:primary_power;}pg_pin(VGND){pg_type:primary_ground;}
        pg_pin(VPB){pg_type:nwell;}pg_pin(VNB){pg_type:pwell;}
        pin(A){direction:input;capacitance:0.1;}
        pin(Y){direction:output;function:"A";power_down_function:"!VPWR";
          timing(){related_pin:A;timing_sense:positive_unate;
            cell_rise(t){values("1,1","1,1");}cell_fall(t){values("1,1","1,1");}
            rise_transition(t){values("0.2,0.2","0.2,0.2");}
            fall_transition(t){values("0.2,0.2","0.2,0.2");}}}}}
    """
    static let pg: [LibertyPGCondition] = [
        .init(pin: "VPWR", sourcePGType: "primary_power", value: true),
        .init(pin: "VGND", sourcePGType: "primary_ground", value: false),
        .init(pin: "VPB", sourcePGType: "nwell", value: true),
        .init(pin: "VNB", sourcePGType: "pwell", value: false)]
    static let source = """
    Actual checked analytic BUF with distributed terminals
    .options temp=25 tnom=27
    .global y
    VDD vdd 0 1
    VIN a 0 0
    XBUF new-buffer:A new-buffer:Y vdd 0 vdd 0 BUF
    .subckt BUF A Y VPWR VGND VPB VNB
    .model charge osdi
    Rcell A Y 2
    NQ Y VGND charge
    .ends BUF
    .tran 1p 10p
    .end
    """
    let root: URL
    let baseline: LogicVerifiedSynthesis
    let assessment: PhysicalLogicECOAssessment
    let prepared: PreparedSTAExecution
    let timing: NativeSTAEngine
    let family: STAConservativeSourceContext
    let spef: Data
    let spefReference: ArtifactReference
    let ir: ParasiticIR
    let library: TimingArtifactBinding
    let manifest: TimingArtifactBinding

    static func make(root: URL) async throws -> Self {
        let helper = PhysicalLogicHandoffTests()
        func bind(_ data: Data, _ name: String, _ format: ArtifactFormat) throws -> TimingArtifactBinding {
            let b = try helper.input(data, name: name, format: format, root: root)
            return try .init(reference: b.reference, availability: .local(artifactID: b.id,
                rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier), relativePath: .init(segments: [name])))
        }
        let source = try helper.input(Data("module top(input a,output y);assign y=a;endmodule".utf8),
            name: "top.sv", format: .systemVerilog, root: root)
        let logicLibrary = try helper.input(Data(liberty.utf8), name: "cells.lib", format: .liberty, root: root)
        let library = try TimingArtifactBinding(reference: logicLibrary.reference, availability: .local(artifactID: logicLibrary.id,
            rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier), relativePath: .init(segments: ["cells.lib"])))
        let manifest = try bind(Data("""
        {"schemaVersion":1,"processID":"whole-candidate-test","version":"1","displayName":"Analytic RC fixture",
        "assets":[{"assetID":"lib","role":"model","path":"cells.lib","kind":"model","format":"LIBERTY",
        "required":true,"cornerIDs":["typical"],"metadata":{},"sha256":"\(library.digest.hexadecimalValue)","byteCount":\(library.byteCount)}],
        "layers":[{"layerID":"m1","name":"M1","number":1,"purpose":"metal","isRoutingLayer":true,"aliases":[]}],
        "devices":[{"deviceID":"buf","modelName":"BUF","terminals":[{"name":"A","role":"input","order":0},
        {"name":"Y","role":"output","order":1}],"parameterNames":[],"aliases":[]}],
        "corners":[{"cornerID":"typical","pvt":{"process":{"name":"tt","nominal":true},"voltage":1,"temperatureCelsius":25},
        "assetIDs":["lib"],"viewMappings":{"liberty":"lib"}}],"crossViewMappings":[{"mappingID":"lib","view":"liberty","assetID":"lib",
        "logicalNames":[],"physicalNames":[],"layerIDs":[],"deviceIDs":["buf"],"cornerIDs":["typical"]}],"metadata":{}}
        """.utf8), "process.json", .json)
        let scope = LogicOperatingProcessScope(libraries: [.init(artifact: library, cornerIDs: ["typical"])],
            pdkManifest: manifest, processID: "whole-candidate-test", pdkVersion: "1", cornerIDs: ["typical"],
            characterizationBindings: [.init(cornerID: "typical", conditionName: "nom", requiredNumericProcess: 1)])
        let synthesis = LogicEngineRuntime.LogicSynthesisRequest(runID: "whole-candidate-baseline",
            sources: [.init(logicalName: "top.sv", artifact: source)], roots: ["top.sv"], top: "top",
            library: logicLibrary, limits: helper.limits(), realizationPolicy: .physicalCells,
            operatingConditionPolicies: [.init(library: logicLibrary.reference, cell: "BUF", cornerID: "typical", conditions: pg)],
            operatingProcessScope: scope)
        let logic = NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
        let executed = try await logic.execute(synthesis)
        let baseline = try await logic.load(executed.receipt, limits: helper.limits())
        var netIDs: [DesignEntityID: String] = [:], portIDs: [DesignEntityID: [String]] = [:]
        var originalNet = ""
        try baseline.mapped.withTables { nets, instances, _, ports, bits, _ in
            let empty = instances.isEmpty
            #expect(empty)
            for net in nets { netIDs[net.id] = "wire" }
            for port in ports {
                let id = port.direction == .input ? "port-a" : "port-y"
                portIDs[port.id] = [id]
                if port.direction == .input {
                    originalNet = "wire"
                    let inputBit = bits[port.bits.lowerBound].rawValue
                    #expect(inputBit == 0)
                }
            }
        }
        #expect(originalNet == "wire")
        let candidate = PhysicalDesignSnapshot(topCell: "top", cells: [.init(id: "new-buffer", master: "BUF", width: 10, height: 10)],
            pins: [.init(id: "port-a", name: "a", netID: "wire", direction: "input"),
                .init(id: "new-buffer/A", cellID: "new-buffer", name: "A", netID: "wire", direction: "input"),
                .init(id: "new-buffer/Y", cellID: "new-buffer", name: "Y", netID: "buffer-output", direction: "output"),
                .init(id: "port-y", name: "y", netID: "buffer-output", direction: "output")],
            nets: [.init(id: "wire", pinIDs: ["port-a", "new-buffer/A"]),
                .init(id: "buffer-output", pinIDs: ["new-buffer/Y", "port-y"])])
        netIDs[try .init(rawValue: UInt64.max - 2)] = "buffer-output"
        let correspondence = PhysicalLogicECOCorrespondence(instanceIDs: [try .init(rawValue: UInt64.max - 1): "new-buffer"],
            netIDs: netIDs, portPinIDs: portIDs, stateInstanceIDs: [:])
        var proof = try context()
        let assessment = try NativePhysicalLogicECOChecker().check(baseline, candidate: candidate,
            correspondence: correspondence, limits: handoffLimits(), context: &proof)
        guard case .equivalent = assessment.verdict else { throw Failure.mismatch("Actual identity ECO proof failed") }
        let design = TimingDesign(topDesignName: "top", ports: [
            .init(name: "a", direction: .input, net: "wire"), .init(name: "y", direction: .output, net: "buffer-output")],
            instances: [.init(name: "new-buffer", cell: "BUF", connections: ["A": "wire", "Y": "buffer-output"])],
            nets: [.init(name: "wire"), .init(name: "buffer-output")])
        let designBinding = try bind(JSONEncoder().encode(design), "sta-design.json", .json)
        // Clockless combinational preparation retains the complete primary AC family.
        // Its explicit global transition is the public conservative source-domain input.
        let constraints = try bind(Data("""
        set_input_transition 0.2ns [all_inputs]
        """.utf8), "sta.sdc", .sdc)
        func node(_ name: String, instance: String? = nil) -> ParasiticNode {
            .init(name: .init(name), kind: .pin, instancePath: instance.map { .init($0) }, coordinate: nil)
        }
        let ni = NetName("wire"), no = NetName("buffer-output")
        func ref(_ net: NetName, _ name: String) -> NodeRef { .init(netName: net, nodeName: .init(name)) }
        let ir = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: .init("typical"), units: .canonical,
            nets: [.init(name: ni, nodes: [node("a"), node("new-buffer:A", instance: "new-buffer")],
                    totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 1),
                .init(name: no, nodes: [node("new-buffer:Y", instance: "new-buffer"), node("y")],
                    totalGroundCapF: 1, totalCouplingCapF: 0, totalResistanceOhm: 1)],
            elements: [.init(id: "Ri", kind: .resistor, nodeA: ref(ni, "a"), nodeB: ref(ni, "new-buffer:A"), value: 1, source: .userDefined),
                .init(id: "Ro", kind: .resistor, nodeA: ref(no, "new-buffer:Y"), nodeB: ref(no, "y"), value: 1, source: .userDefined),
                .init(id: "Co", kind: .capacitor, nodeA: ref(no, "new-buffer:Y"), nodeB: nil, value: 1, source: .userDefined)], metadata: [:])
        // SPEF uses actual logical port names. The SPICE mapping below preserves each physical terminal separately.
        let spef = Data(try SPEFWriter(options: .init(designName: "top", program: "WholeCandidateFlowFixture",
            terminalTokenProfile: .canonical)).write(ir).utf8)
        let parasitics = try bind(spef, "candidate.spef", .spef)
        let reader = FileSystemTimingArtifactReader(workspaceRoot: root)
        let timing = NativeSTAEngine(reader: reader)
        let supplies: [STAOperatingSupplyAssumption] = try pg.map {
            try .init(instance: "new-buffer", cell: "BUF", cornerID: "typical", library: library.reference,
                pin: $0.pin, sourcePGType: $0.sourcePGType, value: $0.value ? .one : .zero)
        }
        let sta = try STARequest(runID: "whole-candidate-sta", design: designBinding, topDesignName: "top",
            libraries: [.init(artifact: library, cornerIDs: ["typical"])], constraints: constraints,
            requestedModeIDs: ["functional"], requestedCornerIDs: ["typical"], pdkManifest: manifest,
            processID: "whole-candidate-test", pdkVersion: "1", parasitics: parasitics,
            characterizationPolicy: .requireObservedConditions,
            characterizationBindings: [.init(cornerID: "typical", conditionName: "nom", requiredNumericProcess: 1)],
            conservativeCoupledRC: .init(maximumNodes: 64, maximumBasisSweeps: 64,
                maximumCertificateAttempts: 16, operatingHistory: .boundedOperatingHistory),
            requireStrictSourceEvidence: true, operatingSupplyAssumptions: supplies)
        let prepared = try await timing.prepare(sta, resources: .init(reader: reader,
            sourceLimits: .init(maximumNestingDepth: 64), sourceResources: STALibertyResources(), limits: .init()))
        let contexts = try timing.initialSourceContexts(prepared)
        let family = try #require(contexts.first)
        #expect(family.record.sources.contains { $0.origin == .primaryPort && $0.history == .unrestricted })
        #expect(family.record.sources.contains { $0.origin == .prescribedCellOutput })
        return .init(root: root, baseline: baseline, assessment: assessment, prepared: prepared,
            timing: timing, family: family, spef: spef, spefReference: parasitics.reference, ir: ir,
            library: library, manifest: manifest)
    }
}

extension WholeCandidateFlowFixture {
    /// Public parsing supplies untrusted coordinate indices only. The producer independently
    /// composes, prepares and checks its own actual model, Jacobian and preconditioner.
    func flow(sdk: WholeCandidateFlowSDKFixture,
        initial: ClosedRange<Double>? = nil, values: ClosedRange<Double>? = nil,
        derivative: ClosedRange<Double>? = nil) async throws -> NativePrescribedVoltageFlowRequest {
        let composed = try PEXSPICEBackannotationComposer(options: .init(topCell: nil,
            subcircuitName: "whole_pex", instanceName: "XPEX_whole", requirePortMatches: true))
            .compose(sourceNetlist: Self.source, ir: ir)
        let lower = try await SPICEIO.parseAndLower(composed, profile: .pinnedNgspiceNormalV1,
            seed: 42, limits: Self.resolutionLimits(), osdiInstances: ["xbuf.nq": sdk.resolved()])
        let topology = MatrixTopology(ir: lower.circuit)
        func node(_ name: String) throws -> Node {
            try #require(lower.circuit.nodeNames.first { $0.value.lowercased() == name.lowercased() }?.key)
        }
        let inputNode = try node("a"), vdd = try node("vdd"), a = try node("new-buffer:A"),
            y = try node("new-buffer:Y"), output = try node("y")
        let selected = try #require(lower.circuit.instances.firstIndex { $0.name.lowercased() == "vin" })
        let supply = try #require(lower.circuit.instances.first { $0.name.lowercased() == "vdd" })
        let input = lower.circuit.instances[selected]
        let inputBranch = try #require(input.ownedBranches.first), supplyBranch = try #require(supply.ownedBranches.first)
        let pRow = try #require(topology.nodeIndex(inputNode))
        let iRow = try #require(topology.variableIndex(for: .branchCurrent(inputBranch)))
        let free = (0..<topology.dimension).filter { $0 != pRow && $0 != iRow }
        #expect(free.count == 5)
        func reduced(_ node: Node) throws -> Int {
            let row = try #require(topology.nodeIndex(node)); return try #require(free.firstIndex(of: row))
        }
        let v = try reduced(vdd), ai = try reduced(a), yi = try reduced(y), oi = try reduced(output)
        let supplyGlobal = try #require(topology.variableIndex(for: .branchCurrent(supplyBranch)))
        let si = try #require(free.firstIndex(of: supplyGlobal))
        let algebraic = free.indices.filter { $0 != yi }
        func equation(_ coordinate: Int) throws -> Int { try #require(algebraic.firstIndex(of: coordinate)) + 1 }
        func inverse(dynamic: Double) throws -> (SparseStructure, [Double]) {
            // H=(3Y-q, Idd, (A-U)+(A-Y)/2, O-Y, Vdd-1), up to the checked row permutation.
            // The initial root replaces the first row with Y-Y0.
            var rows = [[(Int, Double)]](repeating: [], count: free.count)
            rows[yi] = [(0, dynamic)]
            rows[ai] = [(0, dynamic / 3), (try equation(ai), 2.0 / 3)]
            rows[oi] = [(0, dynamic), (try equation(oi), 1)]
            rows[v] = [(try equation(si), 1)]
            rows[si] = [(try equation(v), 1)]
            var pointers = [0], columns: [Int] = [], values: [Double] = []
            for row in rows {
                for (column, value) in row.sorted(by: { $0.0 < $1.0 }) { columns.append(column); values.append(value) }
                pointers.append(columns.count)
            }
            return (try .init(dimension: free.count, rowPointers: pointers, columnIndices: columns), values)
        }
        var lo = [Double](repeating: -2, count: topology.dimension), hi = [Double](repeating: 2, count: topology.dimension)
        lo[pRow] = -0.1; hi[pRow] = 1.1
        lo[try #require(topology.nodeIndex(vdd))] = 0.9; hi[try #require(topology.nodeIndex(vdd))] = 1.1
        for n in [a, y, output] { let r = try #require(topology.nodeIndex(n)); lo[r] = -0.2; hi[r] = 1.2 }
        let first = try inverse(dynamic: 1), window = try inverse(dynamic: 1.0 / 3)
        var centers = [Double](repeating: 0, count: free.count)
        centers[v] = 1; centers[ai] = 0.5; centers[yi] = 0.5; centers[oi] = 0.5; centers[si] = 0
        var start = try centers.map { try Self.ce($0 - 0.05, $0 + 0.05) }
        var slab = start
        start[ai] = try Self.ce(-0.1, 1.1); slab[ai] = try Self.ce(-0.1, 1.1)
        start[yi] = try Self.ce(0.49, 0.51); start[oi] = try Self.ce(0.45, 0.55)
        slab[yi] = try Self.ce(0.2, 0.8); slab[oi] = try Self.ce(0.1, 0.9)
        let primary = try #require(family.record.sources.firstIndex { $0.origin == .primaryPort })
        let slice = try family.jointSlice(sourceAt: primary, initialTime: 0.25...Double(0.25).nextUp,
            over: 0.25...(0.25 + 1e-12).nextUp)
        return try .init(originalLower: lo.map { try .init(high: $0) }, originalUpper: hi.map { try .init(high: $0) },
            startTime: .init(high: 0.25, low: 0x1p-60), duration: .init(high: 1e-12),
            sources: [.init(deviceIndex: selected, zeroVoltage: 0, oneVoltage: 1, timeOrigin: 0, timeScale: 1,
                initialNormalized: initial ?? slice.initialValue, normalized: values ?? slice.windowValue,
                normalizedDerivativePerSecond: derivative ?? slice.almostEverywhereSlope)],
            algebraicRows: algebraic, dynamicInitialCoordinates: [Self.ce(0.499, 0.501)],
            initial: .init(coordinates: start, center: centers.map { try .init(high: $0) }, inverse: first.0, inverseValues: first.1),
            chargeBox: [Self.ce(1.2, 1.8)],
            window: .init(coordinates: slab, center: centers.map { try .init(high: $0) }, inverse: window.0, inverseValues: window.1))
    }
    func request(sdk: WholeCandidateFlowSDKFixture, resources: WholeCandidateFlowResources,
        text: String = Self.source, flow: NativePrescribedVoltageFlowRequest? = nil,
        pinNodes: [String: String]? = nil, cellInstances: [String: String]? = nil,
        rail: PhysicalLogicWholeCandidateRail? = nil, bindings: [PhysicalLogicWholeCandidateSourceBinding]? = nil,
        timingContext: STAConservativeSourceContextRecord? = nil, initialTime: ClosedRange<Double>? = nil,
        window: ClosedRange<Double>? = nil, corner: PEXCornerID = .init("typical"), spefBytes: Data? = nil)
        async throws -> PhysicalLogicWholeCandidateFlowRequest {
        let actualFlow: NativePrescribedVoltageFlowRequest
        if let flow { actualFlow = flow } else { actualFlow = try await self.flow(sdk: sdk) }
        let source = try sdk.source(text, resources: resources)
        let actualBindings = try family.record.sources.enumerated().map { index, source in
            let pin: String
            if source.origin == .primaryPort {
                guard source.authority.endpoint.name == "a" else { throw Failure.mismatch("unexpected primary endpoint") }
                pin = "port-a"
            } else {
                guard source.authority.endpoint.name == "new-buffer:Y" else { throw Failure.mismatch("unexpected cell endpoint") }
                pin = "new-buffer/Y"
            }
            return PhysicalLogicWholeCandidateSourceBinding(sourceIndex: index, physicalPinID: pin,
                sourceDeviceName: source.origin == .primaryPort ? "VIN" : nil)
        }
        return .init(source: source, spefReference: spefReference, spefBytes: spefBytes ?? spef,
            pexCorner: corner, cellInstances: cellInstances ?? ["new-buffer": "XBUF"],
            pinNodes: pinNodes ?? ["port-a": "a", "new-buffer/A": "new-buffer:A", "new-buffer/Y": "new-buffer:Y", "port-y": "y"],
            rail: rail ?? .init(sourceName: "VDD", zeroNode: "0", oneNode: "vdd", zeroVoltage: 0, oneVoltage: 1),
            sourceBindings: bindings ?? actualBindings, timingContext: timingContext ?? family.record,
            initialTimeSI: initialTime ?? 0.25...Double(0.25).nextUp,
            windowSI: window ?? 0.25...(0.25 + 1e-12).nextUp,
            native: .init(osdi: sdk.native, constitutive: sdk.constitutive, capture: sdk.capture, range: sdk.range, flow: actualFlow))
    }
}
