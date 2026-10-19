import Foundation
import CircuiteFoundation

public protocol PhysicalDesignArtifactStore: Sendable {
    func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data

    /// Bounds actual materialization and verifies the exact retained content identity.
    func read(_ binding: PhysicalDesignArtifactBinding, maximumBytes: UInt64) async throws -> Data

    /// Computes the binding that a successful write returns, without publishing bytes.
    func prepareBinding(for artifact: PhysicalDesignArtifactWrite) async throws -> PhysicalDesignArtifactBinding

    /// Commits the complete batch or leaves every previously absent path absent.
    /// An existing path may satisfy a retry only when its bytes exactly match
    /// the requested immutable artifact.
    func write(
        _ artifacts: [PhysicalDesignArtifactWrite]
    ) async throws -> [PhysicalDesignArtifactBinding]
}

extension PhysicalDesignArtifactStore {
    // FIXME(INCOMPLETE_IMPLEMENTATION): Older conformers do not implement bounded reads.
    // Source-budget callers dispatch through this requirement and must fail until the
    // conformer bounds actual I/O/materialization and verifies exact content identity.
    public func read(_ binding: PhysicalDesignArtifactBinding, maximumBytes: UInt64) async throws -> Data {
        throw PhysicalDesignStoreError.readFailed("This store does not support bounded artifact reads.")
    }

    public func prepareBinding(for artifact: PhysicalDesignArtifactWrite) async throws -> PhysicalDesignArtifactBinding {
        throw PhysicalDesignStoreError.writeFailed("This store cannot prepare bindings for atomic stage publication.")
    }

    public func write(
        _ data: Data,
        logicalID: String,
        relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        runID: String
    ) async throws -> PhysicalDesignArtifactBinding {
        let references = try await write([
            PhysicalDesignArtifactWrite(
                data: data,
                logicalID: logicalID,
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
