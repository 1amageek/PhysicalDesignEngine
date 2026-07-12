import Foundation
import XcircuitePackage

public struct FileSystemPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    public let projectRoot: URL
    private let hasher: XcircuiteHasher

    public init(projectRoot: URL, hasher: XcircuiteHasher = XcircuiteHasher()) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.hasher = hasher
    }

    public func read(_ reference: XcircuiteFileReference) async throws -> Data {
        let package = XcircuitePackage(projectRoot: projectRoot)
        let url: URL
        do {
            url = try package.url(forProjectRelativePath: reference.path)
        } catch {
            throw PhysicalDesignStoreError.invalidPath(reference.path)
        }

        do {
            let data = try Data(contentsOf: url)
            if let expectedByteCount = reference.byteCount, Int64(data.count) != expectedByteCount {
                throw PhysicalDesignStoreError.readFailed("\(reference.path): byte count does not match the reference")
            }
            if let expectedDigest = reference.sha256, hasher.sha256(data: data) != expectedDigest {
                throw PhysicalDesignStoreError.readFailed("\(reference.path): SHA-256 digest does not match the reference")
            }
            return data
        } catch {
            throw PhysicalDesignStoreError.readFailed("\(reference.path): \(error.localizedDescription)")
        }
    }

    public func write(
        _ data: Data,
        relativePath: String,
        kind: XcircuiteFileKind,
        format: XcircuiteFileFormat,
        runID: String
    ) async throws -> XcircuiteFileReference {
        let package = XcircuitePackage(projectRoot: projectRoot)
        let url: URL
        do {
            url = try package.url(forProjectRelativePath: relativePath)
        } catch {
            throw PhysicalDesignStoreError.invalidPath(relativePath)
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            let digest = hasher.sha256(data: data)
            return XcircuiteFileReference(
                artifactID: relativePath,
                path: relativePath,
                kind: kind,
                format: format,
                sha256: digest,
                byteCount: Int64(data.count),
                producedByRunID: runID
            )
        } catch let error as PhysicalDesignStoreError {
            throw error
        } catch {
            throw PhysicalDesignStoreError.writeFailed("\(relativePath): \(error.localizedDescription)")
        }
    }
}
