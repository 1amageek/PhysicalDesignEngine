public protocol PhysicalDesignClockTimingModelLoading: Sendable {
    func load(_ reference: PhysicalDesignClockTimingModelReference, for snapshot: PhysicalDesignSnapshot,
              from artifactStore: any PhysicalDesignArtifactStore) async throws -> PhysicalDesignClockCharacterization
}
