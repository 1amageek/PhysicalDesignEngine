import Foundation
import Synchronization
import CircuiteFoundationCrypto

final class PhysicalDesignExportReadStore: PhysicalDesignArtifactStore {
    private let store: any PhysicalDesignArtifactStore
    private let remaining: Mutex<UInt64>

    init(store: any PhysicalDesignArtifactStore, limit: UInt64) {
        self.store = store
        remaining = Mutex(limit)
    }

    func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
        try Task.checkCancellation()
        try charge(binding.reference.byteCount)
        let bytes: Data
        do { bytes = try await store.read(binding) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PhysicalDesignStandardLayoutExportError.artifactReadFailed(error.localizedDescription) }
        try Task.checkCancellation()
        guard UInt64(bytes.count) == binding.reference.byteCount,
              binding.reference.digest.algorithm == .sha256,
              try SHA256ContentDigester().digest(data: bytes, using: .sha256) == binding.reference.digest else {
            throw PhysicalDesignStandardLayoutExportError.sourceIdentityMismatch("Read bytes do not match the declared source identity.")
        }
        return bytes
    }

    func charge(_ count: UInt64) throws {
        try Task.checkCancellation()
        try remaining.withLock { value in
            guard count <= value else {
                throw PhysicalDesignStandardLayoutExportError.limitExceeded(.inputBytes)
            }
            value -= count
        }
    }

    func write(_ artifacts: [PhysicalDesignArtifactWrite]) async throws -> [PhysicalDesignArtifactBinding] {
        throw PhysicalDesignStandardLayoutExportError.encodingFailed("Export source intake cannot write artifacts.")
    }
}
