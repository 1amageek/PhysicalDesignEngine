import CoreSpice

/// Phase ceilings used in addition to the original cumulative invocation ledger.
public struct PhysicalLogicWholeCandidateFlowLimits: Sendable {
    public let handoff: PhysicalLogicHandoffLimits
    public let native: SPICENativeExecutionLimits
    public let flow: NativePrescribedVoltageFlowLimits
    public let observations: NativePrescribedVoltageFlowObservationLimits
    public let maximumSourceBytes: UInt64
    public let maximumSPEFBytes: UInt64
    public let maximumComposedBytes: UInt64
    public let maximumJoinBytes: UInt64
    public let maximumAssociations: Int
    public init(handoff: PhysicalLogicHandoffLimits, native: SPICENativeExecutionLimits,
        flow: NativePrescribedVoltageFlowLimits, observations: NativePrescribedVoltageFlowObservationLimits,
        maximumSourceBytes: UInt64, maximumSPEFBytes: UInt64, maximumComposedBytes: UInt64,
        maximumJoinBytes: UInt64, maximumAssociations: Int) {
        self.handoff = handoff; self.native = native; self.flow = flow; self.observations = observations
        self.maximumSourceBytes = maximumSourceBytes; self.maximumSPEFBytes = maximumSPEFBytes
        self.maximumComposedBytes = maximumComposedBytes; self.maximumJoinBytes = maximumJoinBytes
        self.maximumAssociations = maximumAssociations
    }
}
