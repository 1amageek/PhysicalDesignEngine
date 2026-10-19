import LogicEngineRuntime
import LogicKernelCore
import PhysicalDesignCore

public protocol PhysicalLogicECOChecking: Sendable {
    func check(_ synthesis: LogicVerifiedSynthesis, candidate: PhysicalDesignSnapshot,
               correspondence: PhysicalLogicECOCorrespondence, limits: PhysicalLogicHandoffLimits,
               context: inout LogicKernelContext) throws(PhysicalLogicHandoffError) -> PhysicalLogicECOAssessment
}
