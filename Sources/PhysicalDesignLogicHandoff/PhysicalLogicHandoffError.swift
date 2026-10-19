import LogicKernelCore

public enum PhysicalLogicHandoffError: Error, Sendable, Equatable {
    case kernel(LogicKernelError)
    case invalidMapping(String)
    case logicalMismatch(String)
    case unsupported(String)
    case resourceLimit(String)
}
