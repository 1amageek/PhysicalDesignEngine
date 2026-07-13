import Foundation
import CircuiteFoundation
import XcircuitePackage

public actor InMemoryPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    private var dataByPath: [String: Data] = [:]
    private let hasher: XcircuiteHasher

    public init(hasher: XcircuiteHasher = XcircuiteHasher()) {
        self.hasher = hasher
    }

    public func read(_ reference: XcircuiteFileReference) async throws -> Data {
        guard let data = dataByPath[reference.path] else {
            throw PhysicalDesignStoreError.readFailed("artifact does not exist: \(reference.path)")
        }
        if let expectedByteCount = reference.byteCount, Int64(data.count) != expectedByteCount {
            throw PhysicalDesignStoreError.readFailed("\(reference.path): byte count does not match the reference")
        }
        if let expectedDigest = reference.sha256, hasher.sha256(data: data) != expectedDigest {
            throw PhysicalDesignStoreError.readFailed("\(reference.path): SHA-256 digest does not match the reference")
        }
        return data
    }

    public func write(
        _ data: Data,
        relativePath: String,
        kind: XcircuiteFileKind,
        format: XcircuiteFileFormat,
        runID: String
    ) async throws -> XcircuiteFileReference {
        do {
            _ = try ArtifactLocation(workspaceRelativePath: relativePath)
        } catch {
            throw PhysicalDesignStoreError.invalidPath(relativePath)
        }
        guard dataByPath[relativePath] == nil else {
            throw PhysicalDesignStoreError.pathAlreadyExists(relativePath)
        }
        let digest = hasher.sha256(data: data)
        dataByPath[relativePath] = data
        return XcircuiteFileReference(
            artifactID: artifactID(for: relativePath, kind: kind, format: format, digest: digest),
            path: relativePath,
            kind: kind,
            format: format,
            sha256: digest,
            byteCount: Int64(data.count),
            producedByRunID: runID
        )
    }

    private func artifactID(
        for relativePath: String,
        kind: XcircuiteFileKind,
        format: XcircuiteFileFormat,
        digest: String
    ) -> String {
        let identity = hasher.sha256(data: Data("\(relativePath):\(digest)".utf8))
        return "physical-design-\(kind.rawValue)-\(format.rawValue.lowercased())-\(identity.prefix(16))"
    }

    public func data(at path: String) -> Data? {
        dataByPath[path]
    }
}
