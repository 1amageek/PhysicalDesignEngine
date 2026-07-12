import Foundation
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
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            throw PhysicalDesignStoreError.invalidPath(relativePath)
        }
        dataByPath[relativePath] = data
        return XcircuiteFileReference(
            artifactID: relativePath,
            path: relativePath,
            kind: kind,
            format: format,
            sha256: hasher.sha256(data: data),
            byteCount: Int64(data.count),
            producedByRunID: runID
        )
    }

    public func data(at path: String) -> Data? {
        dataByPath[path]
    }
}
