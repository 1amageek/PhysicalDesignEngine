import Foundation
import CircuiteFoundation

public protocol PhysicalDesignReviewGating: Sendable {
    func prepareReview(
        manifestReference: ArtifactReference,
        decisionScope: [String]
    ) async throws -> PhysicalDesignReviewPacket

    func evaluate(
        _ decision: PhysicalDesignReviewDecision,
        for packet: PhysicalDesignReviewPacket
    ) -> PhysicalDesignReviewResult

    func validateResume(
        _ request: PhysicalDesignResumeRequest,
        packet: PhysicalDesignReviewPacket
    ) -> PhysicalDesignReviewResult

    func validateResumeAgainstCurrentArtifacts(
        _ request: PhysicalDesignResumeRequest,
        packet: PhysicalDesignReviewPacket
    ) async -> PhysicalDesignReviewResult
}
