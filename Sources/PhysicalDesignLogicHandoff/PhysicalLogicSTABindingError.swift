import LogicEngineRuntime
import LogicKernelCore
import STAEngine

/// Preserves lower failures without changing the functional handoff error contract.
public enum PhysicalLogicSTABindingError: Error, Sendable {
    case handoff(PhysicalLogicHandoffError)
    case kernel(LogicKernelError)
    case operatingConditions(LogicOperatingConditionError)
    case design(STADesignBindingError)
    case sta(STAExecutionError)
    case projection(any Error)
}
