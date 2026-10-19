import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem

public struct FileSystemPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    public let projectRoot: URL
    private let hasher: SHA256ContentDigester
    private let referenceBuilder: PhysicalDesignArtifactReferenceBuilder
    private let rootID: ArtifactRootID

    public init(projectRoot: URL, hasher: SHA256ContentDigester = SHA256ContentDigester()) {
        do {
            self.rootID = try ArtifactRootID(rawValue: "physical-design-project")
        } catch {
            preconditionFailure("The static physical-design project root ID is invalid: \(error)")
        }
        self.projectRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.hasher = hasher
        self.referenceBuilder = PhysicalDesignArtifactReferenceBuilder(hasher: hasher)
    }

    public func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
        try await read(binding, maximumBytes: binding.reference.byteCount)
    }

    public func read(_ binding: PhysicalDesignArtifactBinding, maximumBytes: UInt64) async throws -> Data {
        try Task.checkCancellation()
        let reference = binding.reference
        guard reference.byteCount <= maximumBytes,
              let capacity = Int(exactly: reference.byteCount) else {
            throw PhysicalDesignStoreError.readFailed("\(binding.path): reference exceeds the bounded read byte ceiling or platform capacity")
        }
        let relativePath: ArtifactRelativePath
        do {
            let location = try ArtifactLocation(workspaceRelativePath: binding.path)
            _ = try validatedURL(for: location, allowMissingLeaf: false)
            relativePath = try ArtifactRelativePath(segments: binding.path.split(separator: "/").map(String.init))
        } catch {
            throw PhysicalDesignStoreError.invalidPath(binding.path)
        }

        // The byte-only API derives finite page/work limits, without inventing a timeout.
        // A zero-byte reference still needs one terminal page; CF rejects nonempty files
        // against the exact expected count before hashing or materializing their bodies.
        let totalLimit = max(reference.byteCount, 1)
        let pageLimit = min(totalLimit, 1_048_576)
        let pageCount = reference.byteCount == 0 ? 1 : (reference.byteCount - 1) / pageLimit + 1
        let workCount = pageCount.multipliedReportingOverflow(by: 2)
        guard !workCount.overflow else {
            throw PhysicalDesignStoreError.readFailed("\(binding.path): bounded read work count overflow")
        }
        let budget = try ArtifactAccessBudget(
            maximumPageByteCount: pageLimit,
            maximumTotalByteCount: totalLimit,
            maximumPageCount: pageCount,
            maximumWorkUnitCount: workCount.partialValue,
            maximumDurationNanoseconds: UInt64.max
        )
        let root: ArtifactRootCapability
        do {
            root = try ArtifactRootCapability(rootID: rootID, directoryURL: projectRoot, digester: hasher)
        } catch {
            throw PhysicalDesignStoreError.readFailed("\(binding.path): \(error)")
        }
        let outcome: Result<Data, any Error>
        do {
            // Existing store semantics resolve a binding's path in this project root.
            // The caller's availability root label does not grant another filesystem root.
            let intent = try ArtifactAccessIntent(
                expectedReference: reference,
                availability: .local(artifactID: reference.id, rootID: rootID, relativePath: relativePath),
                operation: .read,
                budget: budget
            )
            let session = try await root.open(intent)
            outcome = await readAndClose(session, binding: binding, capacity: capacity, pageLimit: pageLimit)
        } catch {
            outcome = .failure(error)
        }
        let termination = await root.close()
        do {
            try await termination.wait()
        } catch {
            throw PhysicalDesignStoreError.readFailed("\(binding.path): \(failureDescription(outcome)); root close failed: \(error)")
        }
        do {
            let data = try outcome.get()
            try Task.checkCancellation()
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch ArtifactAccessError.cancelled {
            throw CancellationError()
        } catch let error as PhysicalDesignStoreError {
            throw error
        } catch {
            throw PhysicalDesignStoreError.readFailed("\(binding.path): \(error)")
        }
    }

    private func readAndClose(
        _ session: any ArtifactReadSession,
        binding: PhysicalDesignArtifactBinding,
        capacity: Int,
        pageLimit: UInt64
    ) async -> Result<Data, any Error> {
        let outcome: Result<Data, any Error>
        do {
            try Task.checkCancellation()
            var data = Data()
            // The CF open has already admitted actual regular-file size and exact digest.
            // The public Data return boundary requires one bounded owned materialization.
            data.reserveCapacity(capacity)
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let page = try await session.readPage(ArtifactReadPageRequest(offset: offset, maximumByteCount: pageLimit))
                let remaining = binding.reference.byteCount - offset
                guard page.offset == offset, page.bytes.byteCount <= remaining else {
                    throw PhysicalDesignStoreError.readFailed("\(binding.path): page exceeds the admitted exact content extent")
                }
                offset += page.bytes.byteCount
                guard page.cumulativeByteCount == offset else {
                    throw PhysicalDesignStoreError.readFailed("\(binding.path): inconsistent bounded read page count")
                }
                page.bytes.withUnsafeBytes { bytes in
                    data.append(contentsOf: bytes)
                }
                if page.completion == .complete {
                    guard let receipt = page.finalReceipt,
                          receipt.observedArtifactID == binding.reference.id,
                          receipt.totalByteCount == binding.reference.byteCount,
                          offset == binding.reference.byteCount,
                          data.count == capacity else {
                        throw PhysicalDesignStoreError.readFailed("\(binding.path): incomplete or mismatched bounded read receipt")
                    }
                    break
                }
                guard page.bytes.byteCount > 0, offset < binding.reference.byteCount else {
                    throw PhysicalDesignStoreError.readFailed("\(binding.path): bounded read made no progress")
                }
            }
            let actualDigest = try hasher.digest(data: data, using: binding.reference.digest.algorithm)
            guard actualDigest == binding.reference.digest else {
                throw PhysicalDesignStoreError.readFailed("\(binding.path): returned bytes do not match the reference digest")
            }
            try Task.checkCancellation()
            outcome = .success(data)
        } catch {
            outcome = .failure(error)
        }
        let termination = await session.close()
        do {
            let receipt = try await termination.wait()
            if case .success = outcome {
                guard receipt.sessionIdentity == session.identity, receipt.didReachTerminalPage else {
                    return .failure(PhysicalDesignStoreError.readFailed("\(binding.path): bounded read did not terminate completely"))
                }
            }
        } catch {
            return .failure(PhysicalDesignStoreError.readFailed("\(binding.path): \(failureDescription(outcome)); session close failed: \(error)"))
        }
        return outcome
    }

    private func failureDescription(_ outcome: Result<Data, any Error>) -> String {
        switch outcome {
        case .success: "Read completed"
        case .failure(let error): "Read failed: \(error)"
        }
    }

    public func prepareBinding(for artifact: PhysicalDesignArtifactWrite) async throws -> PhysicalDesignArtifactBinding {
        try Task.checkCancellation()
        return try referenceBuilder.makeReference(for: artifact, rootID: rootID)
    }

    public func write(
        _ artifacts: [PhysicalDesignArtifactWrite]
    ) async throws -> [PhysicalDesignArtifactBinding] {
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
                let reference = try referenceBuilder.makeReference(for: artifact, rootID: rootID)
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
        guard url.path == projectRoot.path || url.path.hasPrefix(rootPath) else {
            throw PhysicalDesignStoreError.invalidPath(url.path)
        }
    }
}

private struct PreparedWrite {
    let artifact: PhysicalDesignArtifactWrite
    let destination: URL
    let temporary: URL?
    let reference: PhysicalDesignArtifactBinding
}
