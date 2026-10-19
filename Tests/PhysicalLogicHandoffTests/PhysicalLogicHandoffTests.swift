import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import LogicEngineCore
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import PhysicalDesignCore
import PhysicalDesignLogicHandoff
import Testing

@Suite(.timeLimit(.minutes(2)))
struct PhysicalLogicHandoffTests {
    static let liberty = """
    library(L){cell(AND){area:2;pin(B){direction:input;}pin(Z){direction:output;function:"A B";}pin(A){direction:input;}}
    cell(INV){area:1;pin(Z){direction:output;function:"!A";}pin(A){direction:input;}}
    cell(FF){area:3;ff(S,SN){next_state:"D";clocked_on:"C";clear:"!RN";}pin(Q){direction:output;function:"S";}
    pin(D){direction:input;}pin(C){direction:input;}pin(RN){direction:input;}}
    cell(LATCH){area:3;latch(S,SN){data_in:"D";enable:"G";}pin(Q){direction:output;function:"S";}pin(D){direction:input;}pin(G){direction:input;}}}
    """
    func limits(work: UInt64 = 1_000_000_000, output: UInt64 = 10_000_000, timeout: UInt64 = 10_000_000_000) -> LogicRuntimeLimits {
        var maximums = Dictionary(uniqueKeysWithValues: LogicResource.allCases.map { ($0.rawValue, UInt64(1_000_000_000)) })
        maximums[LogicResource.workUnits.rawValue] = work
        return .init(kernelMaximums: maximums, maximumInputBytes: 50_000_000, maximumOutputBytes: output,
            timeoutNanoseconds: timeout, maximumTokens: 10_000, maximumTableEntries: 500,
            maximumNesting: 64, maximumCutInputs: 3, maximumCellInputs: 4, maximumCutsPerNode: 8,
            firstLibraryEntityID: 100_000, firstMappedEntityID: 1_000_000)
    }
    func input(_ data: Data, name: String, format: ArtifactFormat, root: URL) throws -> LogicArtifactBinding {
        let url = root.appending(path: name); try data.write(to: url)
        return try .local(reference: .init(digest: SHA256ContentDigester().digest(data: data, using: .sha256),
            byteCount: UInt64(data.count), descriptor: .init(role: .input, kind: .rtl, format: format)), fileURL: url)
    }
    func request(root: URL, source: String = "module top(input [7:0] a,b,output [7:0] y);assign y=a&b;endmodule",
                 limits: LogicRuntimeLimits? = nil, realizationPolicy: LogicSynthesisRealizationPolicy = .physicalCells, constraints: LogicSynthesisConstraints = .init()) throws -> LogicEngineRuntime.LogicSynthesisRequest {
        let source = try input(Data(source.utf8), name: "top.sv", format: .systemVerilog, root: root)
        let library = try input(Data(Self.liberty.utf8), name: "cells.lib", format: .liberty, root: root)
        return .init(runID: "actual-runtime", sources: [.init(logicalName: "top.sv", artifact: source)],
            roots: ["top.sv"], top: "top", library: library, limits: limits ?? self.limits(), constraints: constraints, realizationPolicy: realizationPolicy)
    }
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "logic-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func checkedSourceNetlistAdmitsExactPhysicalConnectivityAndRejectsMutations() async throws {
        let root = try temporary(); defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let engine = NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
        let result = try await engine.execute(request(root: root))
        let verified = try await engine.load(result.receipt, limits: limits())
        var cells: [PhysicalDesignSnapshot.Cell] = []; var pins: [PhysicalDesignSnapshot.Pin] = []
        var nets: [PhysicalDesignSnapshot.Net] = []
        var instanceIDs: [DesignEntityID: String] = [:]; var portPins: [DesignEntityID: [String]] = [:]
        try verified.mapped.withTables { logicalNets, instances, connections, ports, bits, _ in
            var members = [[String]](repeating: [], count: logicalNets.count)
            for i in instances.indices {
                let name = "physical-\(i)"; instanceIDs[instances[i].id] = name
                let cell = try verified.mapped.library.cell(at: instances[i].cell)
                cells.append(.init(id: name, master: cell.name, width: 10, height: 10))
                for p in 0..<cell.pinCount {
                    let pin = try cell.pin(at: .init(p)); let id = "\(name)-\(pin.name)"
                    let n = connections[instances[i].pins.lowerBound + p].rawValue
                    members[n].append(id)
                    pins.append(.init(id: id, cellID: name, name: pin.name, netID: "net-\(n)", direction: pin.direction == .input ? "input" : "output"))
                }
            }
            for p in ports.indices {
                var ids: [String] = []
                for b in 0..<ports[p].bits.count {
                    let id = "port-\(p)-\(b)"; let n = bits[ports[p].bits.lowerBound + b].rawValue
                    ids.append(id); members[n].append(id)
                    pins.append(.init(id: id, name: id, netID: "net-\(n)", direction: ports[p].direction == .input ? "input" : "output"))
                }
                portPins[ports[p].id] = ids
            }
            nets = logicalNets.indices.map { .init(id: "net-\($0)", pinIDs: members[$0]) }
        }
        let snapshot = PhysicalDesignSnapshot(topCell: "top", cells: cells, pins: pins, nets: nets)
        let correspondence = PhysicalLogicCorrespondence(instanceIDs: instanceIDs, portPinIDs: portPins)
        let capacities = try PhysicalLogicHandoffLimits(maximumInstances: 100, maximumPins: 200, maximumNets: 100)
        let checker: any PhysicalLogicConnectivityChecking = NativePhysicalLogicConnectivityChecker()
        let checked = try checker.check(verified, snapshot: snapshot, correspondence: correspondence, limits: capacities)
        #expect(checked.snapshot == snapshot && checked.synthesis.mapped.instanceCount == 8)
        var wrongMaster = snapshot; wrongMaster.cells[0].master = "NAND"
        #expect(throws: PhysicalLogicHandoffError.self) { try checker.check(verified, snapshot: wrongMaster, correspondence: correspondence, limits: capacities) }
        var wrongPin = snapshot; wrongPin.pins[0].name = "wrong-pin"
        #expect(throws: PhysicalLogicHandoffError.self) { try checker.check(verified, snapshot: wrongPin, correspondence: correspondence, limits: capacities) }
        var rewired = snapshot
        let oldNet = try #require(rewired.pins[0].netID)
        let newNet = try #require(rewired.pins.first { $0.cellID == cells[0].id && $0.direction == "output" }?.netID)
        rewired.pins[0].netID = newNet
        for n in rewired.nets.indices {
            if rewired.nets[n].id == oldNet { rewired.nets[n].pinIDs.removeAll { $0 == rewired.pins[0].id } }
            if rewired.nets[n].id == newNet { rewired.nets[n].pinIDs.append(rewired.pins[0].id) }
        }
        #expect(throws: PhysicalLogicHandoffError.self) { try checker.check(verified, snapshot: rewired, correspondence: correspondence, limits: capacities) }
        #expect(throws: PhysicalLogicHandoffError.self) { try checker.check(verified, snapshot: snapshot,
            correspondence: .init(instanceIDs: [:], portPinIDs: portPins), limits: capacities) }
        #expect(throws: PhysicalLogicHandoffError.self) { try checker.check(verified, snapshot: snapshot,
            correspondence: correspondence, limits: .init(maximumInstances: 1, maximumPins: 1, maximumNets: 1)) }
    }
    @Test func actualInputlessTiePinsAndConstantsRemainExactAcrossPhysicalHandoff() async throws {
        let root = try temporary(); defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let source = try input(Data("module top(output lo,hi);assign lo=1'b0;assign hi=1'b1;endmodule".utf8), name: "top.sv", format: .systemVerilog, root: root)
        let library = try input(Data(Self.liberty.replacingOccurrences(of: "library(L){", with: "library(L){cell(TIE){area:1;pin(LO){direction:output;function:\"0\";}pin(HI){direction:output;function:\"!0\";}}").utf8), name: "cells.lib", format: .liberty, root: root)
        let engine = NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
        let result = try await engine.execute(.init(runID: "physical-ties", sources: [.init(logicalName: "top.sv", artifact: source)],
            roots: ["top.sv"], top: "top", library: library, limits: limits(), realizationPolicy: .physicalCells))
        let verified = try await engine.load(result.receipt, limits: limits())
        var cells: [PhysicalDesignSnapshot.Cell] = [], pins: [PhysicalDesignSnapshot.Pin] = [], nets: [PhysicalDesignSnapshot.Net] = []
        var instances: [DesignEntityID: String] = [:], portIDs: [DesignEntityID: [String]] = [:]
        try verified.mapped.withTables { logical, mapped, connections, ports, bits, _ in
            var members = [[String]](repeating: [], count: logical.count)
            for instance in mapped {
                let cell = try verified.mapped.library.cell(at: instance.cell)
                #expect(cell.name == "TIE" && cell.pinCount == 2)
                instances[instance.id] = "T1"; cells.append(.init(id: "T1", master: cell.name, width: 100, height: 100))
                for index in 0..<cell.pinCount {
                    let pin = try cell.pin(at: .init(index)); let net = connections[instance.pins.lowerBound + index].rawValue
                    pins.append(.init(id: "T1/" + pin.name, cellID: "T1", name: pin.name, netID: "n\(net)", direction: "output")); members[net].append("T1/" + pin.name)
                }
            }
            for port in ports {
                let id = "port-\(port.id)"; let net = bits[port.bits.lowerBound].rawValue
                portIDs[port.id] = [id]; pins.append(.init(id: id, name: id, netID: "n\(net)", direction: "output")); members[net].append(id)
            }
            nets = logical.indices.map { .init(id: "n\($0)", pinIDs: members[$0]) }
        }
        let snapshot = PhysicalDesignSnapshot(topCell: "top", cells: cells, pins: pins, nets: nets)
        let checker = NativePhysicalLogicConnectivityChecker()
        let capacities = try PhysicalLogicHandoffLimits(maximumInstances: 2, maximumPins: 10, maximumNets: 4)
        #expect(try checker.check(verified, snapshot: snapshot, correspondence: .init(instanceIDs: instances, portPinIDs: portIDs), limits: capacities).snapshot == snapshot)
        var fabricated = snapshot; fabricated.cells[0].master = "SUPPLY_ALIAS"
        #expect(throws: PhysicalLogicHandoffError.self) { try checker.check(verified, snapshot: fabricated,
            correspondence: .init(instanceIDs: instances, portPinIDs: portIDs), limits: capacities) }
    }

    @Test func constantNetCannotBecomePhysicalConnectivityWithoutTieInsertion() async throws {
        let root = try temporary(); defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let engine = NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
        let result = try await engine.execute(request(root: root, source: "module top(output y);assign y=1'b0;endmodule", realizationPolicy: .standardNetlist))
        let verified = try await engine.load(result.receipt, limits: limits())
        let portID = verified.mapped.withTables { _, _, _, ports, _, _ in ports[0].id }
        let snapshot = PhysicalDesignSnapshot(topCell: "top", pins: [.init(id: "y", name: "y", netID: "zero", direction: "output")],
            nets: [.init(id: "zero", pinIDs: ["y"])])
        #expect(throws: PhysicalLogicHandoffError.unsupported("Physical handoff requires a checked physicalCells synthesis receipt")) {
            try NativePhysicalLogicConnectivityChecker().check(verified, snapshot: snapshot,
                correspondence: .init(instanceIDs: [:], portPinIDs: [portID: ["y"]]),
                limits: .init(maximumInstances: 1, maximumPins: 1, maximumNets: 1))
        }
    }

}
