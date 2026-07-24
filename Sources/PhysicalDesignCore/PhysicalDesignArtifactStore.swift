import Foundation
import CircuiteFoundation

public protocol PhysicalDesignArtifactStore: Sendable {
    func read(_ reference: ArtifactReference) async throws -> Data

    /// Commits the complete batch or leaves every previously absent path absent.
    /// An existing path may satisfy a retry only when its bytes exactly match
    /// the requested immutable artifact.
    func write(
        _ artifacts: [PhysicalDesignArtifactWrite]
    ) async throws -> [ArtifactReference]
}

extension PhysicalDesignArtifactStore {
    public func write(
        _ data: Data,
        relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        runID: String
    ) async throws -> ArtifactReference {
        let references = try await write([
            PhysicalDesignArtifactWrite(
                data: data,
                relativePath: relativePath,
                kind: kind,
                format: format,
                runID: runID
            )
        ])
        guard let reference = references.only else {
            throw PhysicalDesignStoreError.writeFailed(
                "Single artifact persistence returned an invalid reference count."
            )
        }
        return reference
    }
}

private extension Collection {
    var only: Element? {
        guard count == 1 else { return nil }
        return first
    }
}
