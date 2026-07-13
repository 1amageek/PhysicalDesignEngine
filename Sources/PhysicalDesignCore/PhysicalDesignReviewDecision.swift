import Foundation
import CircuiteFoundation

public struct PhysicalDesignReviewDecision: Sendable, Hashable, Codable {
    public var decisionID: String
    public var runID: String
    public var stage: PhysicalDesignStage
    public var verdict: PhysicalDesignReviewVerdict
    public var reviewer: String
    public var reviewerKind: PhysicalDesignReviewerKind
    public var note: String
    public var manifestDigest: String
    public var proposedLayoutDigest: String
    public var decisionScope: [String]
    public var createdAt: Date

    public init(
        decisionID: String,
        runID: String,
        stage: PhysicalDesignStage,
        verdict: PhysicalDesignReviewVerdict,
        reviewer: String,
        reviewerKind: PhysicalDesignReviewerKind = .human,
        note: String = "",
        manifestDigest: String,
        proposedLayoutDigest: String,
        decisionScope: [String],
        createdAt: Date = Date()
    ) {
        self.decisionID = decisionID
        self.runID = runID
        self.stage = stage
        self.verdict = verdict
        self.reviewer = reviewer
        self.reviewerKind = reviewerKind
        self.note = note
        self.manifestDigest = manifestDigest
        self.proposedLayoutDigest = proposedLayoutDigest
        self.decisionScope = decisionScope
        self.createdAt = Self.canonicalTimestamp(createdAt)
    }

    private static func canonicalTimestamp(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSinceReferenceDate * 1_000).rounded(.down)
        return Date(timeIntervalSinceReferenceDate: milliseconds / 1_000)
    }
}
