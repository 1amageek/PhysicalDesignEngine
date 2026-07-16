import Foundation
import CircuiteFoundation

public struct FileSystemPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    public let projectRoot: URL
    private let hasher: SHA256ContentDigester

    public init(projectRoot: URL, hasher: SHA256ContentDigester = SHA256ContentDigester()) {
        self.projectRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.hasher = hasher
    }

    public func read(_ reference: ArtifactReference) async throws -> Data {
        let location: ArtifactLocation
        let url: URL
        do {
            location = try ArtifactLocation(workspaceRelativePath: reference.path)
            url = try validatedURL(for: location, allowMissingLeaf: false)
        } catch {
            throw PhysicalDesignStoreError.invalidPath(reference.path)
        }

        do {
            let data = try Data(contentsOf: url)
            if UInt64(data.count) != reference.byteCount {
                throw PhysicalDesignStoreError.readFailed("\(reference.path): byte count does not match the reference")
            }
            let actualDigest = try hasher.digest(data: data, using: reference.digest.algorithm)
            if actualDigest != reference.digest {
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
        kind: ArtifactKind,
        format: ArtifactFormat,
        runID: String
    ) async throws -> ArtifactReference {
        let location: ArtifactLocation
        let url: URL
        do {
            location = try ArtifactLocation(workspaceRelativePath: relativePath)
            url = try validatedURL(for: location, allowMissingLeaf: true)
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
            _ = try validatedURL(for: location, allowMissingLeaf: true)
            try data.write(to: temporaryURL, options: .atomic)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            } catch {
                if FileManager.default.fileExists(atPath: url.path) {
                    throw PhysicalDesignStoreError.pathAlreadyExists(relativePath)
                }
                throw error
            }
            let digest = try hasher.digest(data: data, using: .sha256)
            let locator = ArtifactLocator(
                location: location,
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

    private func validatedURL(
        for location: ArtifactLocation,
        allowMissingLeaf: Bool
    ) throws -> URL {
        let lexicalURL = try location.resolvedFileURL(relativeTo: projectRoot).standardizedFileURL
        let parentURL = lexicalURL.deletingLastPathComponent().resolvingSymlinksInPath()
        try requireContained(parentURL)
        guard parentURL.path == lexicalURL.deletingLastPathComponent().standardizedFileURL.path else {
            throw PhysicalDesignStoreError.invalidPath(location.value)
        }
        if !allowMissingLeaf || FileManager.default.fileExists(atPath: lexicalURL.path) {
            let resolvedURL = lexicalURL.resolvingSymlinksInPath()
            try requireContained(resolvedURL)
            guard resolvedURL.path == lexicalURL.path else {
                throw PhysicalDesignStoreError.invalidPath(location.value)
            }
        }
        return lexicalURL
    }

    private func requireContained(_ url: URL) throws {
        let rootPath = projectRoot.path.hasSuffix("/") ? projectRoot.path : projectRoot.path + "/"
        guard url == projectRoot || url.path.hasPrefix(rootPath) else {
            throw PhysicalDesignStoreError.invalidPath(url.path)
        }
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
}
