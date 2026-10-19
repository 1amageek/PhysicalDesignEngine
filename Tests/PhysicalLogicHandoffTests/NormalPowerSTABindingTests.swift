import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import LogicEngineCore
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PhysicalDesignCore
import PhysicalDesignLogicHandoff
import STAEngine
import Testing
import TimingCore

@Suite(.timeLimit(.minutes(2)))
struct NormalPowerSTABindingTests {
    private static let pg: [LibertyPGCondition] = [
        .init(pin: "VPWR", sourcePGType: "primary_power", value: true),
        .init(pin: "VGND", sourcePGType: "primary_ground", value: false)
    ]
    private static var liberty: String {
        func cell(_ name: String, function: String, area: Int, sense: String) -> String {
            """
            cell(\(name)){area:\(area);
              pg_pin(VPWR){pg_type:primary_power;}pg_pin(VGND){pg_type:primary_ground;}
              pin(A){direction:input;capacitance:0.1;}
              pin(Y){direction:output;function:"\(function)";power_down_function:"!VPWR";
                timing(){related_pin:A;timing_sense:\(sense);
                  cell_rise(t){values("1,1","1,1");}cell_fall(t){values("1,1","1,1");}
                  rise_transition(t){values("0.2,0.2","0.2,0.2");}
                  fall_transition(t){values("0.2,0.2","0.2,0.2");}}}}
            """
        }
        return """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          operating_conditions(nom){process:1;voltage:1;temperature:25;}
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;
            index_1("0,10");index_2("0,10");}
          \(cell("INV", function: "!A", area: 1, sense: "negative_unate"))
          \(cell("BUF", function: "A", area: 2, sense: "positive_unate"))}
        """
    }
    private struct Control: LogicRunControlling {
        let cancelled: Bool
        func checkpoint() throws(LogicKernelError) { if cancelled { throw .cancelled } }
    }
    private func context(limit: UInt64 = 1_000_000_000, storage: UInt64? = nil, cancelled: Bool = false) throws -> LogicKernelContext {
        var maximums = Dictionary(uniqueKeysWithValues: LogicResource.allCases.map { ($0, limit) })
        if let storage { maximums[.managedStorageBytes] = storage }
        return .init(limits: try .init(maximums: maximums),
              control: Control(cancelled: cancelled))
    }
    private func limits() throws -> PhysicalLogicHandoffLimits {
        try .init(maximumInstances: 20, maximumPins: 100, maximumNets: 100)
    }
    private struct Fixture {
        let root: URL
        let baseline: LogicVerifiedSynthesis
        let assessment: PhysicalLogicECOAssessment
        let library: TimingArtifactBinding
        let manifest: TimingArtifactBinding
        let design: TimingDesign
    }
    private func timing(_ binding: LogicArtifactBinding, name: String) throws -> TimingArtifactBinding {
        try .init(reference: binding.reference, availability: .local(artifactID: binding.id,
            rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier), relativePath: .init(segments: [name])))
    }
    private func bind(_ data: Data, name: String, format: ArtifactFormat, root: URL) throws -> TimingArtifactBinding {
        try timing(PhysicalLogicHandoffTests().input(data, name: name, format: format, root: root), name: name)
    }
    private func manifest(library: TimingArtifactBinding, corner: String, root: URL) throws -> TimingArtifactBinding {
        let bytes = Data("""
        {"schemaVersion":1,"processID":"normal-power-test","version":"1","displayName":"Conditional source test",
          "assets":[{"assetID":"lib","role":"model","path":"cells.lib","kind":"model","format":"LIBERTY",
            "required":true,"cornerIDs":["\(corner)"],"metadata":{},
            "sha256":"\(library.digest.hexadecimalValue)","byteCount":\(library.byteCount)}],
          "layers":[{"layerID":"m1","name":"M1","number":1,"purpose":"metal","isRoutingLayer":true,"aliases":[]}],
          "devices":[{"deviceID":"inv","modelName":"INV","terminals":[{"name":"A","role":"input","order":0},
            {"name":"Y","role":"output","order":1}],"parameterNames":[],"aliases":[]}],
          "corners":[{"cornerID":"\(corner)","pvt":{"process":{"name":"tt","nominal":true},"voltage":1,
            "temperatureCelsius":25},"assetIDs":["lib"],"viewMappings":{"liberty":"lib"}}],
          "crossViewMappings":[{"mappingID":"lib","view":"liberty","assetID":"lib","logicalNames":[],
            "physicalNames":[],"layerIDs":[],"deviceIDs":["inv"],"cornerIDs":["\(corner)"]}],"metadata":{}}
        """.utf8)
        return try bind(bytes, name: "process-\(corner).json", format: .json, root: root)
    }
    private func sdc(input: String, output: String) -> String {
        """
        create_clock -name clk -period 10ns [get_ports \(input)]
        set_input_delay 1ns -clock clk [get_ports \(input)]
        set_input_transition 0.2ns [all_inputs]
        set_output_delay 2ns -clock clk [get_ports \(output)]
        """
    }
    private func fixture(root: URL, scoped: Bool = true) async throws -> Fixture {
        let helper = PhysicalLogicHandoffTests()
        let source = try helper.input(Data("module top(input a,output y);assign y=~a;endmodule".utf8),
            name: "top.sv", format: .systemVerilog, root: root)
        let logicLibrary = try helper.input(Data(Self.liberty.utf8), name: "cells.lib", format: .liberty, root: root)
        let library = try timing(logicLibrary, name: "cells.lib")
        let manifest = try manifest(library: library, corner: "typical", root: root)
        let scope: LogicOperatingProcessScope? = scoped ? .init(
            libraries: [.init(artifact: library, cornerIDs: ["typical"])],
            pdkManifest: manifest, processID: "normal-power-test", pdkVersion: "1", cornerIDs: ["typical"],
            characterizationBindings: [.init(cornerID: "typical", conditionName: "nom", requiredNumericProcess: 1)]) : nil
        let request = LogicEngineRuntime.LogicSynthesisRequest(runID: "normal-power-baseline",
            sources: [.init(logicalName: "top.sv", artifact: source)], roots: ["top.sv"], top: "top", library: logicLibrary,
            limits: helper.limits(), realizationPolicy: .physicalCells,
            operatingConditionPolicies: ["INV", "BUF"].map {
                .init(library: logicLibrary.reference, cell: $0, cornerID: scoped ? "typical" : nil, conditions: Self.pg)
            }, operatingProcessScope: scope)
        let engine = NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
        let result = try await engine.execute(request)
        let baseline = try await engine.load(result.receipt, limits: helper.limits())
        var cells: [PhysicalDesignSnapshot.Cell] = [], pins: [PhysicalDesignSnapshot.Pin] = [], nets: [PhysicalDesignSnapshot.Net] = []
        var instanceIDs: [DesignEntityID: String] = [:], netIDs: [DesignEntityID: String] = [:], portIDs: [DesignEntityID: [String]] = [:]
        try baseline.mapped.withTables { logicalNets, instances, connections, ports, bits, _ in
            var members = [[String]](repeating: [], count: logicalNets.count)
            for index in instances.indices {
                let instance = instances[index], name = "physical-\(index)"
                instanceIDs[instance.id] = name
                let cell = try baseline.mapped.library.cell(at: instance.cell)
                cells.append(.init(id: name, master: cell.name, width: 10, height: 10))
                for offset in 0..<cell.pinCount {
                    let pin = try cell.pin(at: .init(offset)), id = name + "/" + pin.name
                    let net = connections[instance.pins.lowerBound + offset].rawValue
                    members[net].append(id)
                    pins.append(.init(id: id, cellID: name, name: pin.name, netID: "net-\(net)",
                        direction: pin.direction == .input ? "input" : "output"))
                }
            }
            for port in ports {
                let name = port.direction == .input ? "a" : "y", id = "port-" + name
                let net = bits[port.bits.lowerBound].rawValue
                portIDs[port.id] = [id]; members[net].append(id)
                pins.append(.init(id: id, name: name, netID: "net-\(net)", direction: port.direction == .input ? "input" : "output"))
            }
            for index in logicalNets.indices {
                let name = "net-\(index)"; netIDs[logicalNets[index].id] = name
                nets.append(.init(id: name, pinIDs: members[index]))
            }
        }
        let output = try #require(pins.firstIndex { $0.id == "port-y" })
        let oldNet = try #require(pins[output].netID)
        let oldIndex = try #require(nets.firstIndex { $0.id == oldNet })
        pins[output].netID = "buffer-output"
        nets[oldIndex].pinIDs.removeAll { $0 == "port-y" }; nets[oldIndex].pinIDs.append("new-buffer/A")
        cells.append(.init(id: "new-buffer", master: "BUF", width: 10, height: 10))
        pins.append(.init(id: "new-buffer/A", cellID: "new-buffer", name: "A", netID: oldNet, direction: "input"))
        pins.append(.init(id: "new-buffer/Y", cellID: "new-buffer", name: "Y", netID: "buffer-output", direction: "output"))
        nets.append(.init(id: "buffer-output", pinIDs: ["new-buffer/Y", "port-y"]))
        instanceIDs[try .init(rawValue: UInt64.max - 1)] = "new-buffer"
        netIDs[try .init(rawValue: UInt64.max - 2)] = "buffer-output"
        let snapshot = PhysicalDesignSnapshot(topCell: "top", cells: cells, pins: pins, nets: nets)
        let correspondence = PhysicalLogicECOCorrespondence(instanceIDs: instanceIDs, netIDs: netIDs,
            portPinIDs: portIDs, stateInstanceIDs: [:])
        var run = try context()
        let assessment = try NativePhysicalLogicECOChecker().check(baseline, candidate: snapshot,
            correspondence: correspondence, limits: limits(), context: &run)
        guard case .equivalent = assessment.verdict else { throw PhysicalLogicHandoffError.logicalMismatch("Identity buffer was not proved") }
        // Independently construct the actual STA input from the concrete fixture's signal pins.
        let timingInstances = try cells.map { cell in
            var connections: [String: String] = [:]
            for pin in pins where pin.cellID == cell.id {
                let net = try #require(pin.netID)
                connections[pin.name] = net
            }
            return TimingDesign.Instance(name: cell.id, cell: cell.master, connections: connections)
        }
        let timingPorts = try pins.filter { $0.cellID == nil }.map {
            TimingDesign.Port(name: $0.name, direction: $0.direction == "input" ? .input : .output, net: try #require($0.netID))
        }
        return .init(root: root, baseline: baseline, assessment: assessment, library: library, manifest: manifest,
            design: .init(topDesignName: "top", ports: timingPorts, instances: timingInstances, nets: nets.map { .init(name: $0.id) }))
    }

    private func prepare(_ fixture: Fixture, design: TimingDesign? = nil, ground: TimingDesign.Constant = .zero,
                         foreignLibrary: Bool = false, corner: String = "typical", strict: Bool = true)
        async throws -> (NativeSTAEngine, PreparedSTAExecution) {
        let actualDesign = design ?? fixture.design
        let designBinding = try bind(JSONEncoder().encode(actualDesign), name: "sta-design.json", format: .json, root: fixture.root)
        let constraints = try bind(Data(sdc(input: "a", output: "y").utf8), name: "sta.sdc", format: .sdc, root: fixture.root)
        let library: TimingArtifactBinding
        if foreignLibrary {
            let reference = try ArtifactReference(digest: fixture.library.digest, byteCount: fixture.library.byteCount,
                descriptor: .init(role: .input, kind: .model, format: .liberty))
            library = try .init(reference: reference, availability: .local(artifactID: reference.id,
                rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier), relativePath: .init(segments: ["cells.lib"])))
        } else { library = fixture.library }
        let manifest = corner == "typical" ? fixture.manifest : try manifest(library: library, corner: corner, root: fixture.root)
        var assumptions: [STAOperatingSupplyAssumption] = []
        for cell in actualDesign.instances {
            assumptions.append(try .init(instance: cell.name, cell: cell.cell, cornerID: corner,
                library: library.reference, pin: "VPWR", sourcePGType: "primary_power", value: .one))
            assumptions.append(try .init(instance: cell.name, cell: cell.cell, cornerID: corner,
                library: library.reference, pin: "VGND", sourcePGType: "primary_ground", value: ground))
        }
        let reader = FileSystemTimingArtifactReader(workspaceRoot: fixture.root)
        let engine = NativeSTAEngine(reader: reader)
        let request = try STARequest(runID: "candidate-sta", design: designBinding, topDesignName: "top",
            libraries: [.init(artifact: library, cornerIDs: [corner])], constraints: constraints,
            requestedModeIDs: ["functional"], requestedCornerIDs: [corner], pdkManifest: manifest,
            processID: "normal-power-test", pdkVersion: "1", characterizationPolicy: .requireObservedConditions,
            characterizationBindings: [.init(cornerID: corner, conditionName: "nom", requiredNumericProcess: 1)],
            requireStrictSourceEvidence: strict, operatingSupplyAssumptions: assumptions)
        let prepared = try await engine.prepare(request, resources: .init(reader: reader,
            sourceLimits: try .init(maximumNestingDepth: 64), sourceResources: STALibertyResources(), limits: try .init()))
        return (engine, prepared)
    }
    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
    }

    @Test func explicitScopeWithoutBaselineSTABindsAddedCellsAndReplaysActualStrictEvidence() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root: root)
        #expect(fixture.baseline.request.operatingProcessScope != nil)
        #expect(fixture.baseline.request.constraints.timing == nil && fixture.baseline.receipt.timingResult == nil)
        #expect(fixture.assessment.mapped.instanceCount == fixture.baseline.mapped.instanceCount + 1)
        var expansion = try context()
        let conditions = try fixture.baseline.qualifyOperatingConditions(fixture.assessment.mapped, context: &expansion)
        #expect(conditions.receipt.records.count == fixture.assessment.candidate.cells.count)
        #expect(conditions.receipt.records.contains { $0.instanceID.rawValue == UInt64.max - 1 && $0.cellName == "BUF" })
        let (engine, prepared) = try await prepare(fixture)
        var initial = try context()
        var lowerOnly = try context()
        for _ in 0..<2 {
            let physicalBefore = initial.usage.counters
            let lowerBefore = lowerOnly.usage.counters
            _ = try fixture.baseline.qualifyOperatingConditions(fixture.assessment.mapped, context: &lowerOnly)
            try fixture.assessment.requirePreparedSTABinding(to: prepared, limits: limits(), context: &initial)
            let physicalAfter = initial.usage.counters
            let lowerAfter = lowerOnly.usage.counters
            let physicalRetained = physicalAfter[.managedStorageBytes, default: 0]
                .subtractingReportingOverflow(physicalBefore[.managedStorageBytes, default: 0])
            let lowerRetained = lowerAfter[.managedStorageBytes, default: 0]
                .subtractingReportingOverflow(lowerBefore[.managedStorageBytes, default: 0])
            #expect(!physicalRetained.overflow && !lowerRetained.overflow)
            #expect(physicalRetained.partialValue == lowerRetained.partialValue)
            let physicalReservations = physicalAfter[.storageReservations, default: 0]
                - physicalBefore[.storageReservations, default: 0]
            let lowerReservations = lowerAfter[.storageReservations, default: 0]
                - lowerBefore[.storageReservations, default: 0]
            #expect(physicalReservations == lowerReservations + 1)
            let physicalAllocation = physicalAfter[.allocationBytes, default: 0]
                - physicalBefore[.allocationBytes, default: 0]
            let lowerAllocation = lowerAfter[.allocationBytes, default: 0]
                - lowerBefore[.allocationBytes, default: 0]
            #expect(physicalAllocation > lowerAllocation)
            #expect(physicalAfter[.workUnits, default: 0] > physicalBefore[.workUnits, default: 0])
        }
        let result = try await engine.execute(prepared)
        #expect(result.status == .completed && result.payload.sourceEvidence != nil)
        let reloaded = try JSONDecoder().decode(STAExecutionResult.self, from: JSONEncoder().encode(result))
        var run = try context()
        try await fixture.assessment.requireSTABinding(to: prepared, result: reloaded,
            validator: engine, limits: limits(), context: &run)
        #expect(run.usage.counters[.workUnits, default: 0] > 0)
    }

    @Test func differentValidSupplyPremiseLibraryCornerAndNonstrictEvidenceAreRejected() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root: root)
        // Both PG choices satisfy !VPWR=false; only the same-premise join must refuse the changed ground value.
        let (_, changedGround) = try await prepare(fixture, ground: .one)
        let (_, foreign) = try await prepare(fixture, foreignLibrary: true)
        let (_, otherCorner) = try await prepare(fixture, corner: "slow")
        let (_, nonstrict) = try await prepare(fixture, strict: false)
        for other in [changedGround, foreign, otherCorner, nonstrict] {
            var run = try context()
            #expect(throws: PhysicalLogicSTABindingError.self) {
                try fixture.assessment.requirePreparedSTABinding(to: other, limits: limits(), context: &run)
            }
        }
    }

    @Test func differentCandidateTopologyAndSavedResultFailDistinctCheckedOwners() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root: root)
        let (engine, prepared) = try await prepare(fixture)
        let result = try await engine.execute(prepared)
        var changed = fixture.design
        let sourceNet = try #require(changed.ports.first { $0.direction == .input }).netName
        changed.instances[changed.instances.count - 1].connections["A"] = sourceNet
        let (otherEngine, otherPrepared) = try await prepare(fixture, design: changed)
        var wrongGraph = try context()
        do {
            try fixture.assessment.requirePreparedSTABinding(to: otherPrepared, limits: limits(), context: &wrongGraph)
            Issue.record("Different physical connectivity acquired the candidate binding")
        } catch PhysicalLogicSTABindingError.design { }
        let otherResult = try await otherEngine.execute(otherPrepared)
        var wrongResult = try context()
        do {
            try await fixture.assessment.requireSTABinding(to: prepared, result: otherResult,
                validator: engine, limits: limits(), context: &wrongResult)
            Issue.record("Saved evidence from another candidate was accepted")
        } catch PhysicalLogicSTABindingError.sta { }
        var differentSnapshot = fixture.assessment.candidate
        differentSnapshot.cells[0].master = "BUF"
        var proofRun = try context()
        let different = try NativePhysicalLogicECOChecker().check(fixture.baseline,
            candidate: differentSnapshot, correspondence: fixture.assessment.correspondence,
            limits: limits(), context: &proofRun)
        guard case .different = different.verdict else { Issue.record("Wrong function was not rejected"); return }
        var differentRun = try context()
        do {
            try different.requirePreparedSTABinding(to: prepared, limits: limits(), context: &differentRun)
            Issue.record("A different functional candidate acquired STA binding")
        } catch PhysicalLogicSTABindingError.handoff(.logicalMismatch) { }
    }

    @Test func sourceOnlyFunctionalScopeIsNeverPromotedToTimingCorner() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root: root, scoped: false)
        let (_, prepared) = try await prepare(fixture)
        var run = try context()
        do {
            try fixture.assessment.requirePreparedSTABinding(to: prepared, limits: limits(), context: &run)
            Issue.record("Source-only conditions acquired a timing corner")
        } catch PhysicalLogicSTABindingError.handoff(.unsupported) { }
        try fixture.assessment.requireBinding(to: fixture.assessment.candidate)
        try fixture.baseline.equivalence.requireBinding(to: fixture.baseline.problem)
    }

    @Test func projectionCountWorkAndCancellationBoundsRemainTyped() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root: root)
        let (_, prepared) = try await prepare(fixture)
        var count = try context()
        let tooSmall = try PhysicalLogicHandoffLimits(maximumInstances: 1, maximumPins: 1, maximumNets: 1)
        #expect(throws: PhysicalLogicSTABindingError.self) {
            try fixture.assessment.requirePreparedSTABinding(to: prepared, limits: tooSmall, context: &count)
        }
        for (limit, cancelled) in [(UInt64(1), false), (UInt64(1_000_000_000), true)] {
            var run = try context(limit: limit, cancelled: cancelled)
            do {
                try fixture.assessment.requirePreparedSTABinding(to: prepared, limits: limits(), context: &run)
                Issue.record("A kernel bound was bypassed")
            } catch PhysicalLogicSTABindingError.kernel { }
        }
        var storage = try context(storage: 1)
        do {
            try fixture.assessment.requirePreparedSTABinding(to: prepared, limits: limits(), context: &storage)
            Issue.record("Condition expansion bypassed its storage reservation")
        } catch PhysicalLogicSTABindingError.operatingConditions(.kernel(.resourceLimit)) { }
    }
}
