import Foundation
import CircuiteFoundation
import XcircuitePackage

public struct FileSystemPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    public let projectRoot: URL
    private let hasher: XcircuiteHasher

    public init(projectRoot: URL, hasher: XcircuiteHasher = XcircuiteHasher()) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.hasher = hasher
    }

    public func read(_ reference: XcircuiteFileReference) async throws -> Data {
        let location: ArtifactLocation
        let url: URL
        do {
            location = try ArtifactLocation(workspaceRelativePath: reference.path)
            url = try location.resolvedFileURL(relativeTo: projectRoot)
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
        } catch let error as PhysicalDesignStoreError {
            throw error
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
        let location: ArtifactLocation
        let url: URL
        do {
            location = try ArtifactLocation(workspaceRelativePath: relativePath)
            url = try location.resolvedFileURL(relativeTo: projectRoot)
        } catch {
            throw PhysicalDesignStoreError.invalidPath(relativePath)
        }

        let temporaryURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw PhysicalDesignStoreError.pathAlreadyExists(relativePath)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: temporaryURL, options: .atomic)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            } catch {
                if FileManager.default.fileExists(atPath: url.path) {
                    throw PhysicalDesignStoreError.pathAlreadyExists(relativePath)
                }
                throw error
            }
            let digest = hasher.sha256(data: data)
            return XcircuiteFileReference(
                artifactID: artifactID(for: relativePath, kind: kind, format: format, digest: digest),
                path: relativePath,
                kind: kind,
                format: format,
                sha256: digest,
                byteCount: Int64(data.count),
                producedByRunID: runID
            )
        } catch let error as PhysicalDesignStoreError {
            do {
                try cleanupTemporaryFile(at: temporaryURL)
            } catch {
                throw PhysicalDesignStoreError.writeFailed(
                    "\(relativePath): \(error.localizedDescription); temporary cleanup also failed"
                )
            }
            throw error
        } catch {
            let primaryMessage = error.localizedDescription
            do {
                try cleanupTemporaryFile(at: temporaryURL)
            } catch {
                throw PhysicalDesignStoreError.writeFailed(
                    "\(relativePath): \(primaryMessage); temporary cleanup also failed: \(error.localizedDescription)"
                )
            }
            throw PhysicalDesignStoreError.writeFailed("\(relativePath): \(primaryMessage)")
        }
    }

    private func cleanupTemporaryFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
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
}
