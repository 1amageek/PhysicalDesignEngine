import Foundation
import CircuiteFoundation

public struct PhysicalDesignPayload: Sendable, Hashable, Codable {
    public var physicalDesign: PhysicalDesignReference?
    public var changedObjectCount: Int
    public var candidateActions: [String]
    public var designDiff: ArtifactReference?
    public var metrics: [PhysicalDesignMetric]
    public var runManifest: ArtifactReference?

    private enum CodingKeys: String, CodingKey {
        case physicalDesign
        case changedObjectCount
        case candidateActions
        case designDiff
        case metrics
        case runManifest
    }

    public init(
        physicalDesign: PhysicalDesignReference?,
        changedObjectCount: Int,
        candidateActions: [String],
        designDiff: ArtifactReference? = nil,
        metrics: [PhysicalDesignMetric] = [],
        runManifest: ArtifactReference? = nil
    ) {
        self.physicalDesign = physicalDesign
        self.changedObjectCount = changedObjectCount
        self.candidateActions = candidateActions
        self.designDiff = designDiff
        self.metrics = metrics
        self.runManifest = runManifest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        physicalDesign = try container.decodeIfPresent(PhysicalDesignReference.self, forKey: .physicalDesign)
        changedObjectCount = try container.decode(Int.self, forKey: .changedObjectCount)
        candidateActions = try container.decode([String].self, forKey: .candidateActions)
        designDiff = try container.decodeIfPresent(ArtifactReference.self, forKey: .designDiff)
        metrics = try container.decodeIfPresent([PhysicalDesignMetric].self, forKey: .metrics) ?? []
        runManifest = try container.decodeIfPresent(ArtifactReference.self, forKey: .runManifest)
    }
}
