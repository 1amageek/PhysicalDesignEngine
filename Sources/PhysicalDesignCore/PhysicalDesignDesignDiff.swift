import CircuiteFoundation
import Foundation

public struct PhysicalDesignDesignDiff: Sendable, Hashable, Codable {
    public enum Domain: String, Sendable, Hashable, Codable { case layout }
    public enum Operation: String, Sendable, Hashable, Codable { case add, replace, metadata }

    public var runID: String
    public var title: String
    public var actor: String
    public var baseSnapshot: ArtifactReference?
    public var proposedSnapshot: ArtifactReference?
    public var changes: [PhysicalDesignDesignDiffChange]
    public var createdAt: Date

    public init(runID: String, title: String, actor: String, baseSnapshot: ArtifactReference?, proposedSnapshot: ArtifactReference?, changes: [PhysicalDesignDesignDiffChange], createdAt: Date) {
        self.runID = runID
        self.title = title
        self.actor = actor
        self.baseSnapshot = baseSnapshot
        self.proposedSnapshot = proposedSnapshot
        self.changes = changes
        self.createdAt = createdAt
    }
}
