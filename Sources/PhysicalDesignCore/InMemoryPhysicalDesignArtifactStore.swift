import Foundation
import CircuiteFoundation

public actor InMemoryPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    private var dataByPath: [String: Data] = [:]
    private let hasher: SHA256ContentDigester

    public init(hasher: SHA256ContentDigester = SHA256ContentDigester()) {
        self.hasher = hasher
    }

    public func read(_ reference: ArtifactReference) async throws -> Data {
        guard let data = dataByPath[reference.path] else {
            throw PhysicalDesignStoreError.readFailed("artifact does not exist: \(reference.path)")
        }
        if UInt64(data.count) != reference.byteCount {
            throw PhysicalDesignStoreError.readFailed("\(reference.path): byte count does not match the reference")
        }
        let actualDigest = try hasher.digest(data: data, using: reference.digest.algorithm)
        if actualDigest != reference.digest {
            throw PhysicalDesignStoreError.readFailed("\(reference.path): SHA-256 digest does not match the reference")
        }
        return data
    }

    public func write(
        _ data: Data,
        relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        runID: String
    ) async throws -> ArtifactReference {
        do {
            _ = try ArtifactLocation(workspaceRelativePath: relativePath)
        } catch {
            throw PhysicalDesignStoreError.invalidPath(relativePath)
        }
        guard dataByPath[relativePath] == nil else {
            throw PhysicalDesignStoreError.pathAlreadyExists(relativePath)
        }
        let digest = try hasher.digest(data: data, using: .sha256)
        dataByPath[relativePath] = data
        let locator = ArtifactLocator(
            location: try ArtifactLocation(workspaceRelativePath: relativePath),
            role: .output,
            kind: kind,
            format: format
        )
        return ArtifactReference(
            id: ArtifactID(stableKey: artifactID(for: relativePath, kind: kind, format: format, digest: digest.hexadecimalValue, runID: runID)),
            locator: locator,
            digest: digest,
            byteCount: UInt64(data.count)
        )
    }

    private func artifactID(
        for relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        digest: String,
        runID: String
    ) -> String {
        "physical-design:\(runID):\(relativePath):\(kind.rawValue):\(format.rawValue):\(digest)"
    }

    public func data(at path: String) -> Data? {
        dataByPath[path]
    }
}
