import Foundation

/// Call-local intake authority for exact source reads, including ProcessInputs.
actor PhysicalDesignRoutingSourceReadStore: PhysicalDesignArtifactStore {
    private let underlying: any PhysicalDesignArtifactStore
    private let allowed: Set<PhysicalDesignArtifactBinding>
    private var remainingBytes: UInt64

    init(underlying: any PhysicalDesignArtifactStore,
         allowed: Set<PhysicalDesignArtifactBinding>, maximumBytes: UInt64) {
        self.underlying = underlying; self.allowed = allowed; remainingBytes = maximumBytes
    }

    func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
        try await read(binding, maximumBytes: binding.reference.byteCount)
    }

    func read(_ binding: PhysicalDesignArtifactBinding, maximumBytes: UInt64) async throws -> Data {
        try Task.checkCancellation()
        let count = binding.reference.byteCount
        guard allowed.contains(binding), count <= maximumBytes, count <= remainingBytes else {
            throw PhysicalDesignRoutingSourceAdoptionError(.limitsExceeded, "Source read exceeds its exact inventory or cumulative allowance.")
        }
        // Debit before suspension so reentrant reads cannot share the same allowance.
        remainingBytes -= count
        return try await underlying.read(binding, maximumBytes: count)
    }

    func write(_ artifacts: [PhysicalDesignArtifactWrite]) async throws -> [PhysicalDesignArtifactBinding] {
        throw PhysicalDesignStoreError.writeFailed("Source adoption intake does not publish artifacts.")
    }
}
