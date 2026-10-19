import LogicEngineRuntime
import PhysicalDesignCore

public protocol PhysicalLogicConnectivityChecking: Sendable {
    func check(_ synthesis: LogicVerifiedSynthesis, snapshot: PhysicalDesignSnapshot,
               correspondence: PhysicalLogicCorrespondence,
               limits: PhysicalLogicHandoffLimits) throws(PhysicalLogicHandoffError) -> CheckedPhysicalLogicHandoff
}
