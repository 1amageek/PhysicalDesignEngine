import Foundation

public struct PhysicalDesignResumeRequest: Sendable, Hashable, Codable {
    public var runID: String
    public var stage: PhysicalDesignStage
    public var manifestDigest: String
    public var expectedBaseLayoutDigest: String?
    public var proposedLayoutDigest: String
    public var decision: PhysicalDesignReviewDecision

    public init(
        runID: String,
        stage: PhysicalDesignStage,
        manifestDigest: String,
        expectedBaseLayoutDigest: String?,
        proposedLayoutDigest: String,
        decision: PhysicalDesignReviewDecision
    ) {
        self.runID = runID
        self.stage = stage
        self.manifestDigest = manifestDigest
        self.expectedBaseLayoutDigest = expectedBaseLayoutDigest
        self.proposedLayoutDigest = proposedLayoutDigest
        self.decision = decision
    }
}
