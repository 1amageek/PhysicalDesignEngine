import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import LogicDesignSerialization
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PhysicalDesignCore

public struct NativePhysicalLogicCheckedCandidatePersistence: PhysicalLogicCheckedCandidatePersisting {
    public init() {}

    private struct Manifest: Codable {
        let schemaVersion: Int
        let baseline: LogicSynthesisReceipt
        let candidate: PhysicalDesignReference
        let netlist: PhysicalDesignArtifactBinding
        let certificate: PhysicalDesignArtifactBinding
        let correspondence: PhysicalLogicECOCorrespondence
        let proofKind: String
    }

    public func persist(_ assessment: PhysicalLogicECOAssessment, candidateReference: PhysicalDesignReference,
                        store: any PhysicalDesignArtifactStore, runID: String, relativeDirectory: String,
                        limits: PhysicalLogicHandoffLimits, maximumArtifactBytes: UInt64,
                        context: inout LogicKernelContext, isolation: isolated (any Actor)? = #isolation)
        async throws(PhysicalLogicCandidateArtifactError) -> PhysicalLogicCheckedCandidateArtifacts {
        do {
            let reservation = try admit(maximumArtifactBytes, context: &context)
            let exported: PhysicalLogicCheckedCandidateArtifacts
            do {
            let bytes = try await read(candidateReference.layoutArtifact, store: store,
                maximumBytes: maximumArtifactBytes, context: &context)
            let candidate = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: bytes)
            try require(candidateReference, snapshot: candidate)
            try assessment.requireBinding(to: candidate)
            guard case .equivalent(let proof) = assessment.verdict else {
                throw PhysicalLogicCandidateArtifactError.invalidBinding("Only an equivalent assessed candidate can be exported")
            }
            try proof.requireBinding(to: assessment.problem)
            let checked = try NativeLogicEquivalenceChecker().recheck(assessment.problem,
                certificate: proof.proof.certificate, context: &context)
            try checked.requireBinding(to: assessment.problem)
            let names = try naming(assessment.mapped, candidate: assessment.candidate,
                correspondence: assessment.correspondence, limits: limits, context: &context)
            let netlist = try MappedGateVerilogCodec().encode(assessment.mapped, top: candidate.topCell,
                naming: names, context: &context)
            try checkSize(netlist, maximumBytes: maximumArtifactBytes, context: &context)
            try admitProof(checked.proof.certificate, maximumBytes: maximumArtifactBytes, context: &context)
            let certificate = try LogicRUPCertificateCodec().encode(checked.proof.certificate)
            try checkSize(certificate, maximumBytes: maximumArtifactBytes, context: &context)
            let netWrite = PhysicalDesignArtifactWrite(data: netlist, logicalID: "physical.logical.checked-candidate.netlist",
                relativePath: relativeDirectory + "/candidate.v", kind: .netlist, format: .verilog, runID: runID)
            let proofWrite = PhysicalDesignArtifactWrite(data: certificate, logicalID: "physical.logical.checked-candidate.rup",
                relativePath: relativeDirectory + "/equivalence-rup.json", kind: .report, format: .json, runID: runID)
            let netBinding = try await store.prepareBinding(for: netWrite)
            let proofBinding = try await store.prepareBinding(for: proofWrite)
            let manifest = Manifest(schemaVersion: 1, baseline: assessment.baseline.receipt,
                candidate: candidateReference, netlist: netBinding, certificate: proofBinding,
                correspondence: assessment.correspondence,
                proofKind: checked.kind == .combinational ? "combinational" : "statePreservingInduction")
            let manifestBytes = try PhysicalDesignJSONCodec().encode(manifest)
            try checkSize(manifestBytes, maximumBytes: maximumArtifactBytes, context: &context)
            let manifestWrite = PhysicalDesignArtifactWrite(data: manifestBytes, logicalID: "physical.logical.checked-candidate.manifest",
                relativePath: relativeDirectory + "/manifest.json", kind: .report, format: .json, runID: runID)
            let manifestBinding = try await store.prepareBinding(for: manifestWrite)
            try context.checkpoint()
            try Task.checkCancellation()
            let published = try await store.write([netWrite, proofWrite, manifestWrite])
            guard published == [netBinding, proofBinding, manifestBinding] else {
                throw PhysicalLogicCandidateArtifactError.invalidBinding("Atomic export returned unexpected artifact bindings")
            }
            exported = .init(candidate: candidateReference, netlist: netBinding, certificate: proofBinding, manifest: manifestBinding)
            } catch {
                try context.releaseStorage(reservation)
                throw error
            }
            try context.releaseStorage(reservation)
            try Task.checkCancellation()
            return exported
        } catch { throw mapped(error) }
    }

    public func reload(_ artifacts: PhysicalLogicCheckedCandidateArtifacts, baseline: LogicVerifiedSynthesis,
                       store: any PhysicalDesignArtifactStore, limits: PhysicalLogicHandoffLimits,
                       maximumArtifactBytes: UInt64, context: inout LogicKernelContext,
                       isolation: isolated (any Actor)? = #isolation)
        async throws(PhysicalLogicCandidateArtifactError) -> PhysicalLogicECOAssessment {
        do {
            let reservation = try admit(maximumArtifactBytes, context: &context)
            let reconstructed: PhysicalLogicECOAssessment
            do {
            let data = try await read(artifacts.manifest, store: store, maximumBytes: maximumArtifactBytes, context: &context)
            let manifest = try PhysicalDesignJSONCodec().decode(Manifest.self, from: data)
            guard manifest.schemaVersion == 1, manifest.baseline == baseline.receipt,
                  manifest.candidate == artifacts.candidate, manifest.netlist == artifacts.netlist,
                  manifest.certificate == artifacts.certificate else {
                throw PhysicalLogicCandidateArtifactError.invalidBinding("Saved candidate export belongs to different input references")
            }
            let snapshotData = try await read(artifacts.candidate.layoutArtifact, store: store,
                maximumBytes: maximumArtifactBytes, context: &context)
            let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: snapshotData)
            try require(artifacts.candidate, snapshot: snapshot)
            guard baseline.request.realizationPolicy == .physicalCells else {
                throw PhysicalLogicCandidateArtifactError.invalidBinding("Candidate reload requires checked physical-cell synthesis")
            }
            try baseline.equivalence.requireBinding(to: baseline.problem)
            let graph = try PhysicalLogicECOProjection.build(baseline, candidate: snapshot,
                correspondence: manifest.correspondence, limits: limits, context: &context)
            try NativeMappedGateRealizationValidator().validate(graph, policy: .physicalCells, context: &context)
            let problem = try PhysicalLogicECOProjection.problem(baseline.original, mapped: graph, context: &context)
            let names = try naming(graph, candidate: snapshot,
                correspondence: manifest.correspondence, limits: limits, context: &context)
            let netlistData = try await read(artifacts.netlist, store: store, maximumBytes: maximumArtifactBytes, context: &context)
            let expectedNetlist = try MappedGateVerilogCodec().encode(graph, top: snapshot.topCell,
                naming: names, context: &context)
            try checkSize(expectedNetlist, maximumBytes: maximumArtifactBytes, context: &context)
            guard netlistData == expectedNetlist else {
                throw PhysicalLogicCandidateArtifactError.invalidBinding("Saved netlist does not describe the exact physical candidate")
            }
            _ = try MappedGateVerilogCodec().decode(netlistData, identities: graph, top: snapshot.topCell,
                naming: names, context: &context)
            let proofData = try await read(artifacts.certificate, store: store, maximumBytes: maximumArtifactBytes, context: &context)
            let certificate = try LogicRUPCertificateCodec().decode(proofData, context: &context)
            let checked = try NativeLogicEquivalenceChecker().recheck(problem, certificate: certificate, context: &context)
            try checked.requireBinding(to: problem)
            let kind = checked.kind == .combinational ? "combinational" : "statePreservingInduction"
            guard manifest.proofKind == kind else {
                throw PhysicalLogicCandidateArtifactError.invalidBinding("Saved proof kind differs from the checked problem")
            }
            reconstructed = .init(baseline: baseline, candidate: snapshot, correspondence: manifest.correspondence,
                mapped: graph, problem: problem, verdict: .equivalent(checked))
            } catch {
                try context.releaseStorage(reservation)
                throw error
            }
            try context.releaseStorage(reservation)
            try Task.checkCancellation()
            return reconstructed
        } catch { throw mapped(error) }
    }

    private func naming(_ graph: MappedGateDesign, candidate: PhysicalDesignSnapshot,
                        correspondence: PhysicalLogicECOCorrespondence, limits: PhysicalLogicHandoffLimits,
                        context: inout LogicKernelContext) throws -> MappedGateVerilogNaming {
        guard candidate.cells.count <= limits.maximumInstances, candidate.pins.count <= limits.maximumPins,
              candidate.nets.count <= limits.maximumNets else { throw PhysicalLogicCandidateArtifactError.capacity }
        var ports: [DesignEntityID: [String]] = [:]
        try graph.withTables { _, _, _, originalPorts, _, _ in
            for index in originalPorts.indices {
                let port = originalPorts[index]
                try context.charge(.workUnits)
                guard let ids = correspondence.portPinIDs[port.id], ids.count == port.bits.count else {
                    throw PhysicalLogicHandoffError.invalidMapping("Missing exported port-bit correspondence")
                }
                var names: [String] = []
                for id in ids {
                    var name: String?
                    for pin in candidate.pins {
                        try context.charge(.workUnits)
                        if pin.id == id { name = pin.name; break }
                    }
                    guard let name else { throw PhysicalLogicHandoffError.invalidMapping("Missing exported physical port name") }
                    names.append(name)
                }
                ports[port.id] = names
            }
        }
        return .init(instanceNames: correspondence.instanceIDs, netNames: correspondence.netIDs, portBitNames: ports)
    }

    private func admit(_ maximum: UInt64, context: inout LogicKernelContext) throws -> LogicStorageReservation {
        try Task.checkCancellation()
        // Reload retains four encoded inputs plus one canonical re-encoding; publication retains four.
        // This covers explicit Data payloads, not opaque JSON decoder allocation or allocator overhead.
        let count = maximum.multipliedReportingOverflow(by: 5)
        guard maximum > 0, !count.overflow else { throw PhysicalLogicCandidateArtifactError.capacity }
        try context.checkpoint()
        return try context.reserveStorage(byteCount: count.partialValue)
    }
    private func checkSize(_ bytes: Data, maximumBytes: UInt64, context: inout LogicKernelContext) throws {
        guard !bytes.isEmpty, UInt64(bytes.count) <= maximumBytes else { throw PhysicalLogicCandidateArtifactError.capacity }
        try context.charge(.expansion, amount: UInt64(bytes.count))
        try context.charge(.workUnits, amount: UInt64(bytes.count))
    }
    private func read(_ binding: PhysicalDesignArtifactBinding, store: any PhysicalDesignArtifactStore,
                      maximumBytes: UInt64, context: inout LogicKernelContext,
                      isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        try Task.checkCancellation()
        guard binding.reference.byteCount > 0, binding.reference.byteCount <= maximumBytes else {
            throw PhysicalLogicCandidateArtifactError.capacity
        }
        try context.charge(.expansion, amount: binding.reference.byteCount)
        try context.checkpoint()
        let bytes = try await store.read(binding)
        try Task.checkCancellation()
        guard UInt64(bytes.count) == binding.reference.byteCount,
              try SHA256ContentDigester().digest(data: bytes, using: .sha256) == binding.reference.digest else {
            throw PhysicalLogicCandidateArtifactError.invalidBinding("Candidate artifact digest or byte count differs")
        }
        try context.charge(.workUnits, amount: UInt64(bytes.count))
        return bytes
    }
    private func require(_ reference: PhysicalDesignReference, snapshot: PhysicalDesignSnapshot) throws {
        guard reference.validationDiagnostics().isEmpty, reference.layoutArtifact.descriptor.format == .json,
              reference.topCell == snapshot.topCell,
              reference.layoutDigest == reference.layoutArtifact.reference.digest.hexadecimalValue else {
            throw PhysicalLogicCandidateArtifactError.invalidBinding("Saved physical candidate identity differs")
        }
    }
    private func admitProof(_ certificate: LogicRUPCertificate, maximumBytes: UInt64,
                            context: inout LogicKernelContext) throws {
        let counts = [certificate.formula.clauseCount, certificate.formula.literalCount,
            certificate.additionCount, certificate.literalCount]
        var bound: UInt64 = 256
        for count in counts {
            let payload = UInt64(count).multipliedReportingOverflow(by: 24)
            let next = bound.addingReportingOverflow(payload.partialValue)
            guard !payload.overflow, !next.overflow else { throw PhysicalLogicCandidateArtifactError.capacity }
            bound = next.partialValue
        }
        guard bound <= maximumBytes else { throw PhysicalLogicCandidateArtifactError.capacity }
        try context.charge(.workUnits, amount: bound)
    }
    private func mapped(_ error: any Error) -> PhysicalLogicCandidateArtifactError {
        if let error = error as? PhysicalLogicCandidateArtifactError { return error }
        if let error = error as? PhysicalLogicHandoffError { return .handoff(error) }
        if let error = error as? LogicKernelError { return .kernel(error) }
        if error is CancellationError { return .cancelled }
        return .underlying(error)
    }
}
