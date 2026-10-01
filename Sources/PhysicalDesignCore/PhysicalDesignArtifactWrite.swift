import CircuiteFoundation
import Foundation

public struct PhysicalDesignArtifactWrite: Sendable {
    public let logicalID: String
    public let data: Data
    public let relativePath: String
    public let kind: ArtifactKind
    public let format: ArtifactFormat
    public let runID: String

    public init(
        data: Data,
        logicalID: String,
        relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        runID: String
    ) {
        self.logicalID = logicalID
        self.data = data
        self.relativePath = relativePath
        self.kind = kind
        self.format = format
        self.runID = runID
    }
}
