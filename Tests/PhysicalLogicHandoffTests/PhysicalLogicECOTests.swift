import CircuiteFoundation
import Foundation
import LogicEngineCore
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import LogicSimulation
import PhysicalDesignCore
import PhysicalDesignLogicHandoff
import Testing

@Suite(.timeLimit(.minutes(2)))
struct PhysicalLogicECOTests {
    private static let liberty = """
    library(L){
    cell(AND){area:2;pin(A){direction:input;}pin(B){direction:input;}pin(Z){direction:output;function:"A B";}}
    cell(TIE){area:1;pin(LO){direction:output;function:"0";}pin(HI){direction:output;function:"!0";}}
    cell(INV){area:1;pin(A){direction:input;}pin(Z){direction:output;function:"!A";}}
    cell(INV2){area:2;pin(A){direction:input;}pin(Z){direction:output;function:"!A";}}
    cell(BUF){area:1;pin(A){direction:input;}pin(Z){direction:output;function:"A";}}
    cell(FF){area:3;ff(S,SN){next_state:"D";clocked_on:"C";clear:"!RN";}
    pin(Q){direction:output;function:"S";}pin(D){direction:input;}pin(C){direction:input;}pin(RN){direction:input;}}
    cell(FF2){area:4;ff(S,SN){next_state:"D";clocked_on:"C";clear:"!RN";}
    pin(Q){direction:output;function:"S";}pin(D){direction:input;}pin(C){direction:input;}pin(RN){direction:input;}}
    cell(FF_BAD){area:5;ff(S,SN){next_state:"D";clocked_on:"C";clear:"RN";}
    pin(Q){direction:output;function:"S";}pin(D){direction:input;}pin(C){direction:input;}pin(RN){direction:input;}}
    cell(FF_FALL){area:6;ff(S,SN){next_state:"D";clocked_on:"!C";clear:"!RN";}
    pin(Q){direction:output;function:"S";}pin(D){direction:input;}pin(C){direction:input;}pin(RN){direction:input;}}
    cell(LATCH){area:3;latch(S,SN){data_in:"D";enable:"G";}
    pin(Q){direction:output;function:"S";}pin(D){direction:input;}pin(G){direction:input;}}
    cell(LATCH2){area:4;latch(S,SN){data_in:"D";enable:"G";}
    pin(Q){direction:output;function:"S";}pin(D){direction:input;}pin(G){direction:input;}}
    cell(LATCH_BAD){area:5;latch(S,SN){data_in:"D";enable:"!G";}
    pin(Q){direction:output;function:"S";}pin(D){direction:input;}pin(G){direction:input;}}
    }
    """
    private struct Fixture {
        let verified: LogicVerifiedSynthesis
        let snapshot: PhysicalDesignSnapshot
        let correspondence: PhysicalLogicECOCorrespondence
    }
    private func context(work: UInt64 = 1_000_000_000, proofBytes: UInt64 = 1_000_000_000,
                         control: any LogicRunControlling = Running()) throws -> LogicKernelContext {
        var maximums = Dictionary(uniqueKeysWithValues: LogicResource.allCases.map { ($0, UInt64(1_000_000_000)) })
        maximums[.workUnits] = work; maximums[.proofBytes] = proofBytes
        return LogicKernelContext(limits: try .init(maximums: maximums), control: control)
    }
    private struct Running: LogicRunControlling { func checkpoint() throws(LogicKernelError) {} }
    private struct Cancelled: LogicRunControlling { func checkpoint() throws(LogicKernelError) { throw .cancelled } }
    private struct Expired: LogicRunControlling { func checkpoint() throws(LogicKernelError) { throw .deadlineExceeded } }
    private func capacities() throws -> PhysicalLogicHandoffLimits {
        try .init(maximumInstances: 100, maximumPins: 1_000, maximumNets: 1_000)
    }
    private func fixture(_ root: URL, source: String = "module top(input a,output y);assign y=~a;endmodule") async throws -> Fixture {
        let helper = PhysicalLogicHandoffTests()
        let sourceBinding = try helper.input(Data(source.utf8), name: "eco.sv", format: .systemVerilog, root: root)
        let library = try helper.input(Data(Self.liberty.utf8), name: "eco.lib", format: .liberty, root: root)
        let engine = NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
        let result = try await engine.execute(.init(runID: "eco-source", sources: [.init(logicalName: "eco.sv", artifact: sourceBinding)],
            roots: ["eco.sv"], top: "top", library: library, limits: helper.limits(), realizationPolicy: .physicalCells))
        let verified = try await engine.load(result.receipt, limits: helper.limits())
        var cells: [PhysicalDesignSnapshot.Cell] = [], pins: [PhysicalDesignSnapshot.Pin] = [], nets: [PhysicalDesignSnapshot.Net] = []
        var instances: [DesignEntityID: String] = [:], netIDs: [DesignEntityID: String] = [:]
        var ports: [DesignEntityID: [String]] = [:], states: [DesignEntityID: String] = [:]
        try verified.mapped.withTables { logicalNets, actual, connections, logicalPorts, bits, _ in
            var members = [[String]](repeating: [], count: logicalNets.count)
            for index in actual.indices {
                let instance = actual[index]; let id = "cell-\(index)"
                instances[instance.id] = id
                if let state = instance.stateID { states[state] = id }
                let cell = try verified.mapped.library.cell(at: instance.cell)
                cells.append(.init(id: id, master: cell.name, width: 10, height: 10))
                for offset in 0..<cell.pinCount {
                    let pin = try cell.pin(at: .init(offset)); let pinID = id + "/" + pin.name
                    let net = connections[instance.pins.lowerBound + offset].rawValue
                    pins.append(.init(id: pinID, cellID: id, name: pin.name, netID: "net-\(net)",
                        direction: pin.direction == .input ? "input" : "output"))
                    members[net].append(pinID)
                }
            }
            for index in logicalPorts.indices {
                let port = logicalPorts[index]; var physicalPins: [String] = []
                for bit in 0..<port.bits.count {
                    let id = "port-\(index)-\(bit)"; let net = bits[port.bits.lowerBound + bit].rawValue
                    physicalPins.append(id); members[net].append(id)
                    pins.append(.init(id: id, name: id, netID: "net-\(net)", direction: port.direction == .input ? "input" : "output"))
                }
                ports[port.id] = physicalPins
            }
            for index in logicalNets.indices {
                let id = "net-\(index)"; netIDs[logicalNets[index].id] = id
                nets.append(.init(id: id, pinIDs: members[index]))
            }
        }
        return .init(verified: verified, snapshot: .init(topCell: "top", cells: cells, pins: pins, nets: nets),
            correspondence: .init(instanceIDs: instances, netIDs: netIDs, portPinIDs: ports, stateInstanceIDs: states))
    }
    private func buffered(_ fixture: Fixture, master: String) throws -> (PhysicalDesignSnapshot, PhysicalLogicECOCorrespondence) {
        var snapshot = fixture.snapshot
        let output = try #require(snapshot.pins.firstIndex { $0.cellID == nil && $0.direction == "output" })
        let oldNet = try #require(snapshot.pins[output].netID)
        let oldIndex = try #require(snapshot.nets.firstIndex { $0.id == oldNet })
        let newNet = "buffer-output"; let cell = "new-buffer"; let input = cell + "/A"; let out = cell + "/Z"
        let topPin = snapshot.pins[output].id
        snapshot.cells.append(.init(id: cell, master: master, width: 10, height: 10))
        snapshot.pins.append(.init(id: input, cellID: cell, name: "A", netID: oldNet, direction: "input"))
        snapshot.pins.append(.init(id: out, cellID: cell, name: "Z", netID: newNet, direction: "output"))
        snapshot.pins[output].netID = newNet
        snapshot.nets[oldIndex].pinIDs.removeAll { $0 == topPin }; snapshot.nets[oldIndex].pinIDs.append(input)
        snapshot.nets.append(.init(id: newNet, pinIDs: [out, topPin]))
        var instances = fixture.correspondence.instanceIDs, nets = fixture.correspondence.netIDs
        instances[try .init(rawValue: UInt64.max - 1)] = cell; nets[try .init(rawValue: UInt64.max - 2)] = newNet
        return (snapshot, .init(instanceIDs: instances, netIDs: nets, portPinIDs: fixture.correspondence.portPinIDs,
                                stateInstanceIDs: fixture.correspondence.stateInstanceIDs))
    }
    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
    }

    @Test func replacementAndIdentityBufferUseActualFunctionsAndPreserveBaselineContract() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root); var run = try context()
        let checker: any PhysicalLogicECOChecking = NativePhysicalLogicECOChecker()
        var replacement = fixture.snapshot; replacement.cells[0].master = "INV2"
        let equivalent = try checker.check(fixture.verified, candidate: replacement, correspondence: fixture.correspondence,
            limits: capacities(), context: &run)
        guard case .equivalent(let proof) = equivalent.verdict else { Issue.record("Correct replacement was not proved"); return }
        try proof.requireBinding(to: equivalent.problem); try equivalent.requireBinding(to: replacement)
        #expect(throws: PhysicalLogicHandoffError.self) { try equivalent.requireBinding(to: fixture.snapshot) }
        #expect(throws: PhysicalLogicHandoffError.self) {
            try NativePhysicalLogicConnectivityChecker().check(fixture.verified, snapshot: replacement,
                correspondence: .init(instanceIDs: fixture.correspondence.instanceIDs, portPinIDs: fixture.correspondence.portPinIDs), limits: capacities())
        }
        let (candidate, correspondence) = try buffered(fixture, master: "BUF")
        let buffered = try checker.check(fixture.verified, candidate: candidate, correspondence: correspondence, limits: capacities(), context: &run)
        guard case .equivalent(let bufferProof) = buffered.verdict else { Issue.record("Identity buffer was not proved"); return }
        #expect(buffered.mapped.instanceCount == fixture.verified.mapped.instanceCount + 1)
        try bufferProof.requireBinding(to: buffered.problem)
        #expect(throws: LogicKernelError.self) { try proof.requireBinding(to: buffered.problem) }
        #expect(fixture.verified.mapped.instanceCount == 1)
    }

    @Test func wrongSamePinReplacementAndInvertingBufferYieldConcreteReplayedDifferences() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root); var run = try context()
        var replacement = fixture.snapshot; replacement.cells[0].master = "BUF"
        let (buffered, correspondence) = try buffered(fixture, master: "INV")
        for (candidate, map) in [(replacement, fixture.correspondence), (buffered, correspondence)] {
            let result = try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: candidate,
                correspondence: map, limits: capacities(), context: &run)
            guard case .different(let witness) = result.verdict else { Issue.record("Wrong actual function was not rejected"); continue }
            try witness.requireBinding(to: result.problem)
            #expect(witness.hasConcreteEventDifference && witness.isAllowedInitialState)
            #expect(witness.referenceEventObservation != nil && witness.candidateEventObservation != nil)
            let inputs = [false], state: [Bool] = []
            let expected = try NativeLogicBinaryEvaluator().evaluate(.bit(fixture.verified.original), inputs: inputs.span, currentState: state.span, context: &run)
            let actual = try NativeLogicBinaryEvaluator().evaluate(.mapped(result.mapped), inputs: inputs.span, currentState: state.span, context: &run)
            expected.withTables { outputs, _ in #expect(outputs[0]) }
            actual.withTables { outputs, _ in #expect(!outputs[0]) }
        }
    }

    @Test func malformedCorrespondencePinsDriversAndUnknownMastersFailBeforeProof() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root)
        var missing = fixture.snapshot; missing.pins.removeLast()
        var unknown = fixture.snapshot; unknown.cells[0].master = "uncompiled-master"
        var wrongPin = fixture.snapshot; wrongPin.pins[0].name = "unknown"
        var wrongDirection = fixture.snapshot; wrongDirection.pins[0].direction = "output"
        var duplicate = fixture.snapshot; duplicate.nets[0].pinIDs.append(duplicate.nets[0].pinIDs[0])
        var undriven = fixture.snapshot
        undriven.nets.append(.init(id: "undriven", pinIDs: []))
        var undrivenIDs = fixture.correspondence.netIDs; undrivenIDs[try .init(rawValue: UInt64.max - 7)] = "undriven"
        let undrivenMap = PhysicalLogicECOCorrespondence(instanceIDs: fixture.correspondence.instanceIDs, netIDs: undrivenIDs,
            portPinIDs: fixture.correspondence.portPinIDs, stateInstanceIDs: [:])
        var aliasedIDs = fixture.correspondence.netIDs
        let keys = Array(aliasedIDs.keys)
        aliasedIDs[keys[0]] = aliasedIDs[keys[1]]
        let aliasMap = PhysicalLogicECOCorrespondence(instanceIDs: fixture.correspondence.instanceIDs, netIDs: aliasedIDs,
            portPinIDs: fixture.correspondence.portPinIDs, stateInstanceIDs: [:])
        var multiplyDriven = fixture.snapshot
        multiplyDriven.cells.append(.init(id: "extra-driver", master: "INV", width: 10, height: 10))
        for pin in fixture.snapshot.pins where pin.cellID != nil {
            let id = "extra-driver/" + pin.name
            multiplyDriven.pins.append(.init(id: id, cellID: "extra-driver", name: pin.name, netID: pin.netID, direction: pin.direction))
            let net = try #require(multiplyDriven.nets.firstIndex { $0.id == pin.netID })
            multiplyDriven.nets[net].pinIDs.append(id)
        }
        var extraInstances = fixture.correspondence.instanceIDs
        extraInstances[try .init(rawValue: UInt64.max - 9)] = "extra-driver"
        let multipleMap = PhysicalLogicECOCorrespondence(instanceIDs: extraInstances, netIDs: fixture.correspondence.netIDs,
            portPinIDs: fixture.correspondence.portPinIDs, stateInstanceIDs: [:])
        let emptyMap = PhysicalLogicECOCorrespondence(instanceIDs: [:], netIDs: fixture.correspondence.netIDs,
            portPinIDs: fixture.correspondence.portPinIDs, stateInstanceIDs: [:])
        for (candidate, correspondence) in [(missing, fixture.correspondence), (unknown, fixture.correspondence),
            (wrongPin, fixture.correspondence), (wrongDirection, fixture.correspondence), (duplicate, fixture.correspondence),
            (undriven, undrivenMap), (multiplyDriven, multipleMap), (fixture.snapshot, aliasMap), (fixture.snapshot, emptyMap)] {
            var run = try context()
            #expect(throws: PhysicalLogicHandoffError.self) {
                try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: candidate,
                    correspondence: correspondence, limits: capacities(), context: &run)
            }
        }
    }

    @Test func explicitStateCorrespondenceSurvivesInstanceReorderingAndRejectsControlChanges() async throws {
        let sources = [
            "module top(input [1:0] d,input c,rn,output logic [1:0] q);always_ff @(posedge c or negedge rn) if(!rn) q<=2'b0; else q<=d;endmodule",
            "module top(input [1:0] d,input g,output logic [1:0] q);always_latch if(g) q<=d;endmodule"
        ]
        for (index, source) in sources.enumerated() {
            let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
            let fixture = try await fixture(root, source: source); var run = try context()
            var replacement = fixture.snapshot
            replacement.cells.reverse()
            for cell in replacement.cells.indices where fixture.correspondence.stateInstanceIDs.values.contains(replacement.cells[cell].id) {
                replacement.cells[cell].master = index == 0 ? "FF2" : "LATCH2"
            }
            let good = try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: replacement,
                correspondence: fixture.correspondence, limits: capacities(), context: &run)
            guard case .equivalent(let proof) = good.verdict else { Issue.record("State-preserving replacement was not proved"); continue }
            #expect(proof.kind == .statePreservingInduction && good.problem.stateBitCount == 2)
            try proof.requireBinding(to: good.problem)
            good.mapped.withTables { _, instances, _, _, _, _ in
                for instance in instances.indices { #expect(instances[instance].initialValue == nil) }
            }
            var wrong = replacement
            for cell in wrong.cells.indices where fixture.correspondence.stateInstanceIDs.values.contains(wrong.cells[cell].id) {
                wrong.cells[cell].master = index == 0 ? "FF_BAD" : "LATCH_BAD"
            }
            let bad = try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: wrong,
                correspondence: fixture.correspondence, limits: capacities(), context: &run)
            switch bad.verdict {
            case .equivalent: Issue.record("Wrong state control was accepted for profile \(index)")
            case .different(let witness):
                try witness.requireBinding(to: bad.problem)
                #expect(witness.hasConcreteEventDifference)
            case .inconclusive(.eventDifferenceNotEstablished(let witness)):
                try witness.requireBinding(to: bad.problem)
                #expect(!witness.hasConcreteEventDifference)
            case .inconclusive: Issue.record("Unexpected interruption or initial-state restriction for profile \(index)")
            }
            // A relation witness may be inconclusive; independently replay a specified
            // concrete event so that the wrong control's actual behavior remains tested.
            let inputs = index == 0 ? [true, true, true, true] : [true, true, true]
            let initial = [false, false]
            let expected = try NativeLogicBinaryEvaluator().replayInitialEvent(.bit(fixture.verified.original),
                inputs: inputs.span, initialState: initial.span, previousControl: false, context: &run)
            let actual = try NativeLogicBinaryEvaluator().replayInitialEvent(.mapped(bad.mapped),
                inputs: inputs.span, initialState: initial.span, previousControl: false, context: &run)
            expected.withStates { states in #expect(states[0] && states[1]) }
            actual.withStates { states in #expect(!states[0] && !states[1]) }
            if index == 0 {
                var falling = replacement
                for cell in falling.cells.indices where fixture.correspondence.stateInstanceIDs.values.contains(falling.cells[cell].id) {
                    falling.cells[cell].master = "FF_FALL"
                }
                #expect(throws: PhysicalLogicHandoffError.self) {
                    try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: falling,
                        correspondence: fixture.correspondence, limits: capacities(), context: &run)
                }
            }
            let missing = PhysicalLogicECOCorrespondence(instanceIDs: fixture.correspondence.instanceIDs,
                netIDs: fixture.correspondence.netIDs, portPinIDs: fixture.correspondence.portPinIDs, stateInstanceIDs: [:])
            #expect(throws: PhysicalLogicHandoffError.self) {
                try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: replacement,
                    correspondence: missing, limits: capacities(), context: &run)
            }
        }
    }

    @Test func projectionCancellationDeadlineAndResourceExhaustionNeverBecomeAssessments() async throws {
        let root = try PhysicalLogicHandoffTests().temporary(); defer { cleanup(root) }
        let fixture = try await fixture(root)
        for (control, expected) in [(Cancelled() as any LogicRunControlling, LogicKernelError.cancelled),
                                    (Expired() as any LogicRunControlling, LogicKernelError.deadlineExceeded)] {
            var run = try context(control: control)
            #expect(throws: PhysicalLogicHandoffError.kernel(expected)) {
                try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: fixture.snapshot,
                    correspondence: fixture.correspondence, limits: capacities(), context: &run)
            }
        }
        var run = try context(work: 1)
        #expect(throws: PhysicalLogicHandoffError.self) {
            try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: fixture.snapshot,
                correspondence: fixture.correspondence, limits: capacities(), context: &run)
        }
        var proofLimited = try context(proofBytes: 1)
        let unproved = try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: fixture.snapshot,
            correspondence: fixture.correspondence, limits: capacities(), context: &proofLimited)
        guard case .inconclusive(.interrupted(.resourceLimit(let resource, _, _))) = unproved.verdict else {
            Issue.record("Proof resource exhaustion became a successful verdict"); return
        }
        #expect(resource == .proofBytes)
        try unproved.requireBinding(to: fixture.snapshot)
        #expect(unproved.problem.inputBitCount == 1 && unproved.mapped.instanceCount == 1)
        var limited = try context()
        #expect(throws: PhysicalLogicHandoffError.self) {
            try NativePhysicalLogicECOChecker().check(fixture.verified, candidate: fixture.snapshot,
                correspondence: fixture.correspondence,
                limits: .init(maximumInstances: 1, maximumPins: 1, maximumNets: 1), context: &limited)
        }
    }
}
