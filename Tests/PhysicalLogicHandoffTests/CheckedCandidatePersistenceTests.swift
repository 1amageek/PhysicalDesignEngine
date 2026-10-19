import CircuiteFoundation
import Foundation
import LogicEngineCore
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PhysicalDesignCore
import PhysicalDesignLogicHandoff
import Testing

@Suite("Checked physical candidate artifact persistence", .serialized, .timeLimit(.minutes(2)))
struct CheckedCandidatePersistenceTests {
    private struct Control: LogicRunControlling {
        let cancelled: Bool
        func checkpoint() throws(LogicKernelError) { if cancelled { throw .cancelled } }
    }
    private func context(cancelled: Bool = false) throws -> LogicKernelContext {
        .init(limits: try .init(maximums: Dictionary(uniqueKeysWithValues:
            LogicResource.allCases.map { ($0, UInt64(1_000_000_000)) })), control: Control(cancelled: cancelled))
    }
    private func limits() throws -> PhysicalLogicHandoffLimits {
        try .init(maximumInstances: 100, maximumPins: 1000, maximumNets: 1000)
    }
    private struct Fixture {
        let root: URL
        let baseline: LogicVerifiedSynthesis
        let assessment: PhysicalLogicECOAssessment
        let reference: PhysicalDesignReference
        let store: InMemoryPhysicalDesignArtifactStore
    }
    private let codec = PhysicalDesignJSONCodec()
    private func fixture(alternateLibrary: Bool = false) async throws -> Fixture {
        let helper = PhysicalLogicHandoffTests(), root = try helper.temporary()
        let source = try helper.input(Data("module top(input a,b,output y);assign y=a&b;endmodule".utf8), name: "top.sv", format: .systemVerilog, root: root)
        let library = try helper.input(Data((PhysicalLogicHandoffTests.liberty + (alternateLibrary ? "\n " : "")).utf8), name: "cells.lib", format: .liberty, root: root)
        let engine = NativeLogicSynthesisEngine(artifactStore: FileSystemLogicArtifactStore(rootDirectory: root))
        let result = try await engine.execute(.init(runID: "export-source", sources: [.init(logicalName: "top.sv", artifact: source)],
            roots: ["top.sv"], top: "top", library: library, limits: helper.limits(), realizationPolicy: .physicalCells))
        let baseline = try await engine.load(result.receipt, limits: helper.limits())
        var cells: [PhysicalDesignSnapshot.Cell] = [], pins: [PhysicalDesignSnapshot.Pin] = [], nets: [PhysicalDesignSnapshot.Net] = []
        var instanceIDs: [DesignEntityID: String] = [:], netIDs: [DesignEntityID: String] = [:], portIDs: [DesignEntityID: [String]] = [:]
        try baseline.mapped.withTables { logicalNets, instances, connections, ports, bits, _ in
            var members = [[String]](repeating: [], count: logicalNets.count)
            for index in instances.indices {
                let instance = instances[index], id = "physical/and-\(index)"
                let cell = try baseline.mapped.library.cell(at: instance.cell)
                instanceIDs[instance.id] = id; cells.append(.init(id: id, master: cell.name, width: 10, height: 10))
                for offset in 0..<cell.pinCount {
                    let pin = try cell.pin(at: .init(offset)), n = connections[instance.pins.lowerBound + offset].rawValue
                    let pinID = id + "/" + pin.name; members[n].append(pinID)
                    pins.append(.init(id: pinID, cellID: id, name: pin.name, netID: "physical-net-\(n)", direction: pin.direction == .input ? "input" : "output"))
                }
            }
            for index in ports.indices {
                var ids: [String] = []
                for bit in 0..<ports[index].bits.count {
                    let id = "terminal-\(index)-\(bit)", n = bits[ports[index].bits.lowerBound + bit].rawValue
                    members[n].append(id); ids.append(id)
                    pins.append(.init(id: id, name: id, netID: "physical-net-\(n)", direction: ports[index].direction == .input ? "input" : "output"))
                }
                portIDs[ports[index].id] = ids
            }
            for index in logicalNets.indices {
                let id = "physical-net-\(index)"; netIDs[logicalNets[index].id] = id
                nets.append(.init(id: id, pinIDs: members[index]))
            }
        }
        let snapshot = PhysicalDesignSnapshot(topCell: "top", cells: cells, pins: pins, nets: nets)
        var run = try context()
        let assessment = try NativePhysicalLogicECOChecker().check(baseline, candidate: snapshot,
            correspondence: .init(instanceIDs: instanceIDs, netIDs: netIDs, portPinIDs: portIDs, stateInstanceIDs: [:]), limits: limits(), context: &run)
        let store = InMemoryPhysicalDesignArtifactStore()
        let binding = try await store.write(codec.encode(snapshot), logicalID: "saved-candidate", relativePath: "candidate.json", kind: .layout, format: .json, runID: "export-source")
        return .init(root: root, baseline: baseline, assessment: assessment,
            reference: .init(layoutArtifact: binding, topCell: "top", layoutDigest: binding.reference.digest.hexadecimalValue), store: store)
    }
    private func cleanup(_ root: URL) { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
    private func persist(_ fixture: Fixture, directory: String = "checked") async throws -> PhysicalLogicCheckedCandidateArtifacts {
        var run = try context()
        return try await NativePhysicalLogicCheckedCandidatePersistence().persist(fixture.assessment,
            candidateReference: fixture.reference, store: fixture.store, runID: "export", relativeDirectory: directory,
            limits: limits(), maximumArtifactBytes: 1_000_000, context: &run)
    }
    private func forged(_ artifacts: PhysicalLogicCheckedCandidateArtifacts, fixture: Fixture, proof: Bool) async throws -> PhysicalLogicCheckedCandidateArtifacts {
        let kind = proof ? "certificate" : "netlist"
        let replacement = try await fixture.store.write(Data((proof ? "{}" : "module wrong();endmodule").utf8), logicalID: "forged-" + kind,
            relativePath: "forged-" + kind, kind: proof ? .report : .netlist, format: proof ? .json : .verilog, runID: "export")
        let original = try await fixture.store.read(artifacts.manifest)
        var manifest = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        manifest[kind] = try JSONSerialization.jsonObject(with: codec.encode(replacement))
        let manifestBytes = try JSONSerialization.data(withJSONObject: manifest)
        let binding = try await fixture.store.write(manifestBytes, logicalID: "forged-manifest-" + kind,
            relativePath: "forged-manifest-" + kind + ".json", kind: .report, format: .json, runID: "export")
        return .init(candidate: artifacts.candidate, netlist: proof ? artifacts.netlist : replacement,
            certificate: proof ? replacement : artifacts.certificate, manifest: binding)
    }

    private actor ReadHandshake {
        private var entered = false
        private var released = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var resumeRead: CheckedContinuation<Void, Never>?
        private(set) var returnedReads = 0

        func pauseRead() async {
            entered = true
            arrival?.resume(); arrival = nil
            if !released { await withCheckedContinuation { resumeRead = $0 } }
        }
        func waitForRead() async {
            if !entered { await withCheckedContinuation { arrival = $0 } }
        }
        func releaseRead() {
            released = true
            resumeRead?.resume(); resumeRead = nil
        }
        func recordReturnedData() { returnedReads += 1 }
    }

    private struct PausingReadStore: PhysicalDesignArtifactStore {
        let base: any PhysicalDesignArtifactStore
        let handshake: ReadHandshake
        func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
            // Finish the real read before exposing the cancellation handshake. The
            // underlying store may cooperatively refuse reads begun after cancellation.
            let bytes = try await base.read(binding)
            await handshake.pauseRead()
            // Deliberately return retained normal data after cancellation so the
            // caller's post-read checkpoint, rather than the store, owns this refusal.
            await handshake.recordReturnedData()
            return bytes
        }
        func prepareBinding(for artifact: PhysicalDesignArtifactWrite) async throws -> PhysicalDesignArtifactBinding {
            try await base.prepareBinding(for: artifact)
        }
        func write(_ artifacts: [PhysicalDesignArtifactWrite]) async throws -> [PhysicalDesignArtifactBinding] {
            try await base.write(artifacts)
        }
    }

    @Test("Swift Task cancellation after a normal store read refuses checked reload with noncancelled kernel control")
    func taskCancellationAfterNormalRead() async throws {
        let fixture = try await fixture(); defer { cleanup(fixture.root) }
        let artifacts = try await persist(fixture)
        let handshake = ReadHandshake()
        let store = PausingReadStore(base: fixture.store, handshake: handshake)
        let task = Task {
            var run = try context(cancelled: false)
            return try await NativePhysicalLogicCheckedCandidatePersistence().reload(artifacts,
                baseline: fixture.baseline, store: store, limits: limits(), maximumArtifactBytes: 1_000_000,
                context: &run)
        }
        await handshake.waitForRead()
        task.cancel()
        await handshake.releaseRead()
        var cancelled = false
        do {
            _ = try await task.value
            Issue.record("Cancelled Swift Task returned a checked assessment")
        } catch let error as PhysicalLogicCandidateArtifactError {
            if case .cancelled = error { cancelled = true }
            else { Issue.record("Swift Task cancellation was not preserved: \(error)") }
        }
        #expect(cancelled)
        #expect(await handshake.returnedReads >= 1)
    }

    @Test("Saved physical-name netlist and RUP reload checked; rebound tampering and stale library fail")
    func checkedReloadAndTampering() async throws {
        let fixture = try await fixture(); defer { cleanup(fixture.root) }
        let artifacts = try await persist(fixture)
        let persistence = NativePhysicalLogicCheckedCandidatePersistence()
        var run = try context()
        let reloaded = try await persistence.reload(artifacts, baseline: fixture.baseline, store: fixture.store,
            limits: limits(), maximumArtifactBytes: 1_000_000, context: &run)
        try reloaded.requireBinding(to: fixture.assessment.candidate)
        guard case .equivalent(let checked) = reloaded.verdict else { Issue.record("Reload did not check the saved certificate"); return }
        try checked.requireBinding(to: reloaded.problem)
        let bytes = try await fixture.store.read(artifacts.netlist)
        #expect(String(decoding: bytes, as: UTF8.self).contains("\\physical/and-0 "))
        for proof in [false, true] {
            let changed = try await forged(artifacts, fixture: fixture, proof: proof)
            var negative = try context()
            await #expect(throws: PhysicalLogicCandidateArtifactError.self) {
                _ = try await persistence.reload(changed, baseline: fixture.baseline, store: fixture.store,
                    limits: limits(), maximumArtifactBytes: 1_000_000, context: &negative)
            }
        }
        let foreign = try await self.fixture(alternateLibrary: true); defer { cleanup(foreign.root) }
        #expect(foreign.baseline.request.library.reference != fixture.baseline.request.library.reference)
        var stale = try context()
        await #expect(throws: PhysicalLogicCandidateArtifactError.self) {
            _ = try await persistence.reload(artifacts, baseline: foreign.baseline, store: fixture.store,
                limits: limits(), maximumArtifactBytes: 1_000_000, context: &stale)
        }
    }

    @Test("Different saved candidate, byte limits, cancellation and atomic path conflict cannot publish success")
    func refusalAndAtomicity() async throws {
        let fixture = try await fixture(); defer { cleanup(fixture.root) }
        let persistence = NativePhysicalLogicCheckedCandidatePersistence()
        var changed = fixture.assessment.candidate; changed.cells[0].x += 1
        let different = try await fixture.store.write(codec.encode(changed), logicalID: "different-candidate",
            relativePath: "different.json", kind: .layout, format: .json, runID: "export")
        let reference = PhysicalDesignReference(layoutArtifact: different, topCell: "top", layoutDigest: different.reference.digest.hexadecimalValue)
        var run = try context()
        await #expect(throws: PhysicalLogicCandidateArtifactError.self) {
            _ = try await persistence.persist(fixture.assessment, candidateReference: reference, store: fixture.store,
                runID: "export", relativeDirectory: "different", limits: limits(), maximumArtifactBytes: 1_000_000, context: &run)
        }
        for cancelled in [false, true] {
            var bounded = try context(cancelled: cancelled)
            await #expect(throws: PhysicalLogicCandidateArtifactError.self) {
                _ = try await persistence.persist(fixture.assessment, candidateReference: fixture.reference, store: fixture.store,
                    runID: "export", relativeDirectory: "bounded", limits: limits(), maximumArtifactBytes: 1, context: &bounded)
            }
        }
        let good = try await persist(fixture)
        let occupied = try await fixture.store.write(Data("occupied".utf8), logicalID: "occupied", relativePath: "conflict/equivalence-rup.json",
            kind: .report, format: .json, runID: "export")
        var conflict = try context()
        await #expect(throws: PhysicalLogicCandidateArtifactError.self) {
            _ = try await persistence.persist(fixture.assessment, candidateReference: fixture.reference, store: fixture.store,
                runID: "export", relativeDirectory: "conflict", limits: limits(), maximumArtifactBytes: 1_000_000, context: &conflict)
        }
        let netlistBytes = try await fixture.store.read(good.netlist)
        let unpublished = try await fixture.store.prepareBinding(for: .init(data: netlistBytes,
            logicalID: "physical.logical.checked-candidate.netlist", relativePath: "conflict/candidate.v", kind: .netlist, format: .verilog, runID: "export"))
        await #expect(throws: PhysicalDesignStoreError.self) { _ = try await fixture.store.read(unpublished) }
        let stillOccupied = try await fixture.store.read(occupied)
        #expect(stillOccupied == Data("occupied".utf8))
    }
}
