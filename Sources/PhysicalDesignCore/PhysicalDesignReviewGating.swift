import Foundation
import XcircuitePackage

public protocol PhysicalDesignReviewGating: Sendable {
    func prepareReview(
        manifestReference: XcircuiteFileReference,
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
}
