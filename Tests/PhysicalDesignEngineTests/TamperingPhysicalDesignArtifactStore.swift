import Foundation
import CircuiteFoundation
@testable import PhysicalDesignCore

actor TamperingPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    private let base: InMemoryPhysicalDesignArtifactStore
    private var tamperedPath: String?

    init(base: InMemoryPhysicalDesignArtifactStore) {
        self.base = base
    }

    func setTamperedPath(_ path: String) {
        tamperedPath = path
    }

    func read(_ reference: ArtifactReference) async throws -> Data {
        if reference.path == tamperedPath {
            return Data("tampered artifact".utf8)
        }
        return try await base.read(reference)
    }

    func write(
        _ data: Data,
        relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        runID: String
    ) async throws -> ArtifactReference {
        try await base.write(
            data,
            relativePath: relativePath,
            kind: kind,
            format: format,
            runID: runID
        )
    }
}
