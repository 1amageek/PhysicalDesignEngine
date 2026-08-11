import Foundation
import CircuiteFoundation

public struct PhysicalDesignPayload: Sendable, Hashable, Codable {
    public var physicalDesign: PhysicalDesignReference?
    public var changedObjectCount: Int
    public var candidateActions: [String]
    public var designDiff: PhysicalDesignArtifactBinding?
    public var metrics: [PhysicalDesignMetric]
    public var runManifest: PhysicalDesignArtifactBinding?
    public var stageCompletionEvidence: PhysicalDesignArtifactBinding?
    public var claims: PhysicalDesignCapabilityClaims

    public init(
        physicalDesign: PhysicalDesignReference?,
        changedObjectCount: Int,
        candidateActions: [String],
        designDiff: PhysicalDesignArtifactBinding? = nil,
        metrics: [PhysicalDesignMetric] = [],
        runManifest: PhysicalDesignArtifactBinding? = nil,
        stageCompletionEvidence: PhysicalDesignArtifactBinding? = nil,
        claims: PhysicalDesignCapabilityClaims = .blocked
    ) {
        self.physicalDesign = physicalDesign
        self.changedObjectCount = changedObjectCount
        self.candidateActions = candidateActions
        self.designDiff = designDiff
        self.metrics = metrics
        self.runManifest = runManifest
        self.stageCompletionEvidence = stageCompletionEvidence
        self.claims = claims
    }

}
