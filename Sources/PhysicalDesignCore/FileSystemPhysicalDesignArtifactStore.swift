import Foundation
import CircuiteFoundation

public struct FileSystemPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    public let projectRoot: URL
    private let hasher: SHA256ContentDigester
    private let referenceBuilder: PhysicalDesignArtifactReferenceBuilder

    public init(projectRoot: URL, hasher: SHA256ContentDigester = SHA256ContentDigester()) {
        self.projectRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.hasher = hasher
        self.referenceBuilder = PhysicalDesignArtifactReferenceBuilder(hasher: hasher)
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
        _ artifacts: [PhysicalDesignArtifactWrite]
    ) async throws -> [ArtifactReference] {
        var uniquePaths = Set<String>()
        var prepared: [PreparedWrite] = []
        do {
            for artifact in artifacts {
                guard uniquePaths.insert(artifact.relativePath).inserted else {
                    throw PhysicalDesignStoreError.invalidPath(
                        "duplicate batch path: \(artifact.relativePath)"
                    )
                }
                let location: ArtifactLocation
                let destination: URL
                do {
                    location = try ArtifactLocation(
                        workspaceRelativePath: artifact.relativePath
                    )
                    destination = try validatedURL(
                        for: location,
                        allowMissingLeaf: true
                    )
                } catch {
                    throw PhysicalDesignStoreError.invalidPath(artifact.relativePath)
                }
                let reference = try referenceBuilder.makeReference(for: artifact)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let existing = try Data(contentsOf: destination, options: .mappedIfSafe)
                    guard existing == artifact.data else {
                        throw PhysicalDesignStoreError.pathAlreadyExists(
                            artifact.relativePath
                        )
                    }
                    prepared.append(
                        PreparedWrite(
                            artifact: artifact,
                            destination: destination,
                            temporary: nil,
                            reference: reference
                        )
                    )
                    continue
                }

                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try validatedURL(for: location, allowMissingLeaf: true)
                let temporary = destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
                    )
                try artifact.data.write(to: temporary, options: .atomic)
                prepared.append(
                    PreparedWrite(
                        artifact: artifact,
                        destination: destination,
                        temporary: temporary,
                        reference: reference
                    )
                )
            }

            var committed: [PreparedWrite] = []
            do {
                for item in prepared {
                    guard let temporary = item.temporary else { continue }
                    if FileManager.default.fileExists(atPath: item.destination.path) {
                        let existing = try Data(
                            contentsOf: item.destination,
                            options: .mappedIfSafe
                        )
                        guard existing == item.artifact.data else {
                            throw PhysicalDesignStoreError.pathAlreadyExists(
                                item.artifact.relativePath
                            )
                        }
                        try cleanupTemporaryFile(at: temporary)
                        continue
                    }
                    do {
                        try FileManager.default.moveItem(
                            at: temporary,
                            to: item.destination
                        )
                    } catch {
                        guard FileManager.default.fileExists(
                            atPath: item.destination.path
                        ) else {
                            throw error
                        }
                        let existing = try Data(
                            contentsOf: item.destination,
                            options: .mappedIfSafe
                        )
                        guard existing == item.artifact.data else {
                            throw PhysicalDesignStoreError.pathAlreadyExists(
                                item.artifact.relativePath
                            )
                        }
                        try cleanupTemporaryFile(at: temporary)
                        continue
                    }
                    committed.append(item)
                }
            } catch {
                let cleanupFailures = rollback(
                    committed: committed,
                    prepared: prepared
                )
                if !cleanupFailures.isEmpty {
                    throw PhysicalDesignStoreError.writeFailed(
                        "\(error.localizedDescription); rollback failed: \(cleanupFailures.joined(separator: "; "))"
                    )
                }
                throw error
            }
            return prepared.map(\.reference)
        } catch let error as PhysicalDesignStoreError {
            let cleanupFailures = cleanupTemporaryFiles(in: prepared)
            if !cleanupFailures.isEmpty {
                throw PhysicalDesignStoreError.writeFailed(
                    "\(error.localizedDescription); temporary cleanup failed: \(cleanupFailures.joined(separator: "; "))"
                )
            }
            throw error
        } catch {
            let cleanupFailures = cleanupTemporaryFiles(in: prepared)
            let suffix = cleanupFailures.isEmpty
                ? ""
                : "; temporary cleanup failed: \(cleanupFailures.joined(separator: "; "))"
            throw PhysicalDesignStoreError.writeFailed(
                "\(error.localizedDescription)\(suffix)"
            )
        }
    }

    private func cleanupTemporaryFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func cleanupTemporaryFiles(
        in prepared: [PreparedWrite]
    ) -> [String] {
        var failures: [String] = []
        for item in prepared {
            guard let temporary = item.temporary else { continue }
            do {
                try cleanupTemporaryFile(at: temporary)
            } catch {
                failures.append(
                    "\(temporary.path): \(error.localizedDescription)"
                )
            }
        }
        return failures
    }

    private func rollback(
        committed: [PreparedWrite],
        prepared: [PreparedWrite]
    ) -> [String] {
        var failures = cleanupTemporaryFiles(in: prepared)
        for item in committed.reversed() {
            do {
                let stored = try Data(
                    contentsOf: item.destination,
                    options: .mappedIfSafe
                )
                guard stored == item.artifact.data else {
                    failures.append(
                        "\(item.destination.path): committed bytes changed before rollback"
                    )
                    continue
                }
                try FileManager.default.removeItem(at: item.destination)
            } catch {
                failures.append(
                    "\(item.destination.path): \(error.localizedDescription)"
                )
            }
        }
        return failures
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
}

private struct PreparedWrite {
    let artifact: PhysicalDesignArtifactWrite
    let destination: URL
    let temporary: URL?
    let reference: ArtifactReference
}
