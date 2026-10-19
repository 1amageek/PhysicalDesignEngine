import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PhysicalDesignCore

public struct NativePhysicalLogicECOChecker: PhysicalLogicECOChecking {
    public init() {}

    public func check(_ synthesis: LogicVerifiedSynthesis, candidate: PhysicalDesignSnapshot,
                      correspondence: PhysicalLogicECOCorrespondence, limits: PhysicalLogicHandoffLimits,
                      context: inout LogicKernelContext) throws(PhysicalLogicHandoffError) -> PhysicalLogicECOAssessment {
        guard synthesis.request.realizationPolicy == .physicalCells else {
            throw .unsupported("ECO admission requires checked physicalCells synthesis")
        }
        do {
            try synthesis.equivalence.requireBinding(to: synthesis.problem)
            let mapped = try PhysicalLogicECOProjection.build(synthesis, candidate: candidate,
                correspondence: correspondence, limits: limits, context: &context)
            try NativeMappedGateRealizationValidator().validate(mapped, policy: .physicalCells, context: &context)
            let problem = try PhysicalLogicECOProjection.problem(synthesis.original, mapped: mapped, context: &context)
            let checker = NativeLogicEquivalenceChecker()
            let verdict: LogicEquivalenceVerdict
            switch try checker.check(problem, context: &context) {
            case .equivalent(let found):
                try found.requireBinding(to: problem)
                do throws(LogicKernelError) {
                    let checked = try checker.recheck(problem, certificate: found.proof.certificate, context: &context)
                    try checked.requireBinding(to: problem)
                    verdict = .equivalent(checked)
                } catch {
                    switch error {
                    case .resourceLimit, .cancelled, .deadlineExceeded: verdict = .inconclusive(.interrupted(error))
                    default: throw error
                    }
                }
            case .different(let witness):
                try witness.requireBinding(to: problem)
                verdict = .different(witness)
            case .inconclusive(let reason): verdict = .inconclusive(reason)
            }
            return .init(baseline: synthesis, candidate: candidate, correspondence: correspondence, mapped: mapped,
                         problem: problem, verdict: verdict)
        } catch let error as PhysicalLogicHandoffError { throw error }
        catch let error as LogicKernelError { throw .kernel(error) }
        catch { throw .invalidMapping("ECO admission failed: \(error)") }
    }
}
