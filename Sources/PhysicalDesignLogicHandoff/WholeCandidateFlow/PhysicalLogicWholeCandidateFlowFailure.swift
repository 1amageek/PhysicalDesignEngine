import CoreSpice

public enum PhysicalLogicWholeCandidateFlowFailure: Error, Sendable {
    public enum Phase: Sendable { case candidate, source, parasitics, family }
    case lower(phase: Phase, cause: any Error)
    case invalidInput(String)
    case candidate(String)
    case source(String)
    case parasitics(String)
    case rail(String)
    case time(String)
    case family(sourceIndex: Int, reason: String)
    case internalOutput(sourceIndex: Int, reason: String)
    case resource(any Error)
    case cancelled
    case native(any Error)
    indirect case stagingCleanup(PhysicalLogicWholeCandidateStagingCleanupFailure)
    indirect case cleanup(primary: Self, secondary: OSDIAdapterFailure)
}
