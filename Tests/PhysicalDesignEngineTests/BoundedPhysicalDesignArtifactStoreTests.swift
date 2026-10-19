import Foundation
import Testing
import CircuiteFoundation
@testable import PhysicalDesignCore

@Suite("Bounded physical artifact stores", .timeLimit(.minutes(1)))
struct BoundedPhysicalDesignArtifactStoreTests {
    @Test("legacy conformers explicitly refuse bounded dispatch without calling unbounded read")
    func defaultBoundedRequirementDoesNotFallback() async throws {
        let memory = InMemoryPhysicalDesignArtifactStore()
        let binding = try await memory.registerInput(Data("source".utf8), relativePath: "source.txt", kind: .netlist, format: .json)
        let legacy = LegacyReadStore()
        let store: any PhysicalDesignArtifactStore = legacy
        await expectReadFailure { try await store.read(binding, maximumBytes: binding.reference.byteCount) }
        #expect(await legacy.readCount == 0)
    }

    @Test("memory reads admit exact and empty bounds and reject declared and retained excess")
    func memoryBoundsAndExactIdentity() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let bytes = Data("source".utf8)
        let binding = try await store.registerInput(bytes, relativePath: "source.txt", kind: .netlist, format: .json)
        let bounded: any PhysicalDesignArtifactStore = store
        #expect(try await bounded.read(binding, maximumBytes: 6) == bytes)
        #expect(try await bounded.read(binding) == bytes)
        await expectReadFailure { try await bounded.read(binding, maximumBytes: 5) }
        let shortClaim = try replacingByteCount(binding, with: 1)
        await expectReadFailure { try await bounded.read(shortClaim, maximumBytes: 1) }
        let different = try await store.registerInput(Data("forged".utf8), relativePath: "different.txt", kind: .netlist, format: .json)
        guard case .local(_, let rootID, let path) = binding.availability else {
            throw PhysicalDesignStoreError.invalidPath("Expected local test binding")
        }
        let forged = try PhysicalDesignArtifactBinding(logicalID: binding.logicalID, reference: different.reference, availability: .local(artifactID: different.reference.id, rootID: rootID, relativePath: path))
        await expectReadFailure { try await bounded.read(forged, maximumBytes: 6) }
        let empty = try await store.registerInput(Data(), relativePath: "empty.txt", kind: .netlist, format: .json)
        #expect(try await bounded.read(empty, maximumBytes: 0).isEmpty)
    }

    @Test("filesystem exact and empty reads work through both protocol requirements")
    func filesystemExactAndEmptyBounds() async throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let store: any PhysicalDesignArtifactStore = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let bytes = Data(repeating: 0x5A, count: 1_048_577)
        let binding = try await store.write(bytes, logicalID: "source", relativePath: "source.bin", kind: .netlist, format: .json, runID: "bounded")
        #expect(try await store.read(binding, maximumBytes: UInt64(bytes.count)) == bytes)
        #expect(try await store.read(binding) == bytes)
        await expectReadFailure { try await store.read(binding, maximumBytes: UInt64(bytes.count - 1)) }
        let empty = try await store.write(Data(), logicalID: "empty", relativePath: "empty.bin", kind: .netlist, format: .json, runID: "bounded")
        #expect(try await store.read(empty, maximumBytes: 0).isEmpty)
        #expect(try await store.read(empty).isEmpty)
    }

    @Test("a file enlarged beyond its retained reference is refused before body materialization")
    func filesystemRejectsActualSparseGrowth() async throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let binding = try await store.write(Data("source".utf8), logicalID: "source", relativePath: "source.bin", kind: .netlist, format: .json, runID: "bounded")
        let file = try FileHandle(forWritingTo: root.appendingPathComponent("source.bin"))
        do {
            // Sparse growth exercises actual size admission without allocating its body.
            try file.truncate(atOffset: 64 * 1_048_576)
            try file.close()
        } catch {
            do { try file.close() } catch { Issue.record("File cleanup failed: \(error)") }
            throw error
        }
        await expectReadFailure { try await store.read(binding, maximumBytes: binding.reference.byteCount) }
        await expectReadFailure { try await store.read(binding) }
        // A larger caller cap does not relax the exact reference count.
        await expectReadFailure { try await store.read(binding, maximumBytes: 64 * 1_048_576) }
    }

    @Test("same-size digest replacement and shortening cannot return successful bytes")
    func filesystemRejectsChangedContent() async throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let binding = try await store.write(Data("source".utf8), logicalID: "source", relativePath: "source.bin", kind: .netlist, format: .json, runID: "bounded")
        let url = root.appendingPathComponent("source.bin")
        try Data("forged".utf8).write(to: url)
        await expectReadFailure { try await store.read(binding, maximumBytes: 6) }
        try Data("s".utf8).write(to: url)
        await expectReadFailure { try await store.read(binding, maximumBytes: 6) }
    }

    @Test("nonregular and symlink replacements are refused by real filesystem intake")
    func filesystemRejectsNonregularAndSymlink() async throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let binding = try await store.write(Data("source".utf8), logicalID: "source", relativePath: "source.bin", kind: .netlist, format: .json, runID: "bounded")
        let url = root.appendingPathComponent("source.bin")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await expectReadFailure { try await store.read(binding, maximumBytes: 6) }
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("target.bin")
        try Data("source".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        do {
            _ = try await store.read(binding, maximumBytes: 6)
            Issue.record("Symlink replacement unexpectedly succeeded")
        } catch let error as PhysicalDesignStoreError {
            switch error {
            case .invalidPath(let path):
                #expect(path == binding.path)
            case .readFailed(let reason):
                // Descriptor-relative CF intake may detect the symlink after path admission.
                #expect(reason.contains("symlinkTraversal(componentIndex: 0)"))
            default:
                Issue.record("Unexpected symlink failure: \(error)")
            }
        }
    }

    @Test("flat artifacts use root path identity independently of a URL directory flag")
    func flatArtifactsIgnoreRootDirectoryRepresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "physical-flat-root-\(UUID().uuidString)")
        // Construct before creation to deterministically retain a non-directory URL.
        // Actual retained routing roots exhibit the same flag mismatch while existing.
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        #expect(!store.projectRoot.hasDirectoryPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeRoot(root) }
        let bytes = Data("flat source".utf8)
        let binding = try await store.write(bytes, logicalID: "flat", relativePath: "flat.json", kind: .report, format: .json, runID: "flat")
        #expect(try await store.read(binding, maximumBytes: UInt64(bytes.count)) == bytes)
        #expect(try await store.read(binding) == bytes)

        let outside = try makeRoot()
        defer { removeRoot(outside) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: outside)
        do {
            _ = try await store.write(bytes, logicalID: "outside", relativePath: "escape/outside.json", kind: .report, format: .json, runID: "flat")
            Issue.record("Outside-root symlink write unexpectedly succeeded")
        } catch let error as PhysicalDesignStoreError {
            #expect(error == .invalidPath("escape/outside.json"))
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "outside.json").path))
    }

    @Test("cancelled tasks retain cancellation for both concrete bounded stores")
    func cancelledTasksRefuseReads() async throws {
        let root = try makeRoot()
        defer { removeRoot(root) }
        let memory = InMemoryPhysicalDesignArtifactStore()
        let memoryBinding = try await memory.registerInput(Data("source".utf8), relativePath: "source.bin", kind: .netlist, format: .json)
        let filesystem = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        let fileBinding = try await filesystem.write(Data("source".utf8), logicalID: "source", relativePath: "source.bin", kind: .netlist, format: .json, runID: "bounded")
        #expect(await cancelledRead(store: memory, binding: memoryBinding))
        #expect(await cancelledRead(store: filesystem, binding: fileBinding))
        // Cancellation belonged to child tasks and did not poison subsequent reads.
        #expect(try await filesystem.read(fileBinding, maximumBytes: 6) == Data("source".utf8))
    }

    private func expectReadFailure(_ body: () async throws -> Data) async {
        do {
            _ = try await body()
            Issue.record("Bounded artifact read unexpectedly succeeded")
        } catch let error as PhysicalDesignStoreError {
            guard case .readFailed = error else {
                Issue.record("Unexpected store failure: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected read error: \(error)")
        }
    }

    private func cancelledRead(store: any PhysicalDesignArtifactStore, binding: PhysicalDesignArtifactBinding) async -> Bool {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.read(binding, maximumBytes: binding.reference.byteCount)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
    }

    private func replacingByteCount(_ binding: PhysicalDesignArtifactBinding, with count: UInt64) throws -> PhysicalDesignArtifactBinding {
        let reference = try ArtifactReference(digest: binding.reference.digest, byteCount: count, descriptor: binding.reference.descriptor)
        guard case .local(_, let rootID, let path) = binding.availability else {
            throw PhysicalDesignStoreError.invalidPath("Expected local test binding")
        }
        return try PhysicalDesignArtifactBinding(logicalID: binding.logicalID, reference: reference, availability: .local(artifactID: reference.id, rootID: rootID, relativePath: path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-physical-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeRoot(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Temporary bounded-store cleanup failed: \(error)") }
    }
}

private actor LegacyReadStore: PhysicalDesignArtifactStore {
    private(set) var readCount = 0

    func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
        readCount += 1
        return Data("unbounded".utf8)
    }

    func write(_ artifacts: [PhysicalDesignArtifactWrite]) async throws -> [PhysicalDesignArtifactBinding] {
        throw PhysicalDesignStoreError.writeFailed("Read-only test store")
    }
}
