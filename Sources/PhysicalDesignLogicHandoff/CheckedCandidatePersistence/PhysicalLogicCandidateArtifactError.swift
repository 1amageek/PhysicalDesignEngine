import LogicKernelCore

public enum PhysicalLogicCandidateArtifactError: Error, Sendable {
    case invalidBinding(String)
    case capacity
    case cancelled
    case kernel(LogicKernelError)
    case handoff(PhysicalLogicHandoffError)
    case underlying(any Error)
}
