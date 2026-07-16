import Foundation
import CircuiteFoundation

public struct PhysicalDesignPayload: Sendable, Hashable, Codable {
    public var physicalDesign: PhysicalDesignReference?
    public var changedObjectCount: Int
    public var candidateActions: [String]
    public var designDiff: ArtifactReference?
    public var metrics: [PhysicalDesignMetric]
    public var runManifest: ArtifactReference?
    public var claims: PhysicalDesignCapabilityClaims

    public init(
        physicalDesign: PhysicalDesignReference?,
        changedObjectCount: Int,
        candidateActions: [String],
        designDiff: ArtifactReference? = nil,
        metrics: [PhysicalDesignMetric] = [],
        runManifest: ArtifactReference? = nil,
        claims: PhysicalDesignCapabilityClaims = .blocked
    ) {
        self.physicalDesign = physicalDesign
        self.changedObjectCount = changedObjectCount
        self.candidateActions = candidateActions
        self.designDiff = designDiff
        self.metrics = metrics
        self.runManifest = runManifest
        self.claims = claims
    }

}
