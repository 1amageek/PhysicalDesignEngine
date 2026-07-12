import Foundation
import XcircuitePackage

public struct PhysicalDesignReference: Sendable, Hashable, Codable {
    public var layoutArtifact: XcircuiteFileReference
    public var topCell: String
    public var layoutDigest: String

    public init(
        layoutArtifact: XcircuiteFileReference,
        topCell: String,
        layoutDigest: String
    ) {
        self.layoutArtifact = layoutArtifact
        self.topCell = topCell
        self.layoutDigest = layoutDigest
    }
}

