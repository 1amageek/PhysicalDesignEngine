import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PhysicalDesignCore

public struct PhysicalLogicECOAssessment: Sendable {
    public let baseline: LogicVerifiedSynthesis
    public let candidate: PhysicalDesignSnapshot
    public let correspondence: PhysicalLogicECOCorrespondence
    public let mapped: MappedGateDesign
    public let problem: LogicEquivalenceProblem
    public let verdict: LogicEquivalenceVerdict

    internal init(baseline: LogicVerifiedSynthesis, candidate: PhysicalDesignSnapshot, correspondence: PhysicalLogicECOCorrespondence,
                  mapped: MappedGateDesign, problem: LogicEquivalenceProblem, verdict: LogicEquivalenceVerdict) {
        self.baseline = baseline; self.candidate = candidate; self.correspondence = correspondence
        self.mapped = mapped; self.problem = problem; self.verdict = verdict
    }

    public func requireBinding(to candidate: PhysicalDesignSnapshot) throws(PhysicalLogicHandoffError) {
        guard self.candidate == candidate else { throw .logicalMismatch("ECO assessment belongs to a different candidate snapshot") }
    }
}
