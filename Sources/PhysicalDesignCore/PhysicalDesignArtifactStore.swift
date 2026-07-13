import Foundation
import CircuiteFoundation

public protocol PhysicalDesignArtifactStore: Sendable {
    func read(_ reference: ArtifactReference) async throws -> Data

    func write(
        _ data: Data,
        relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        runID: String
    ) async throws -> ArtifactReference
}
