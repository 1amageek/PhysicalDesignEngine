import LogicEngineRuntime
import LogicKernelCore
import PhysicalDesignCore

public protocol PhysicalLogicCheckedCandidatePersisting: Sendable {
    func persist(_ assessment: PhysicalLogicECOAssessment, candidateReference: PhysicalDesignReference,
                 store: any PhysicalDesignArtifactStore, runID: String, relativeDirectory: String,
                 limits: PhysicalLogicHandoffLimits, maximumArtifactBytes: UInt64,
                 context: inout LogicKernelContext, isolation: isolated (any Actor)?)
        async throws(PhysicalLogicCandidateArtifactError) -> PhysicalLogicCheckedCandidateArtifacts

    func reload(_ artifacts: PhysicalLogicCheckedCandidateArtifacts, baseline: LogicVerifiedSynthesis,
                store: any PhysicalDesignArtifactStore, limits: PhysicalLogicHandoffLimits,
                maximumArtifactBytes: UInt64, context: inout LogicKernelContext,
                isolation: isolated (any Actor)?)
        async throws(PhysicalLogicCandidateArtifactError) -> PhysicalLogicECOAssessment
}
