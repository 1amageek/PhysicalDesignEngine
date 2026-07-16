public protocol PhysicalDesignClockTimingModelLoading: Sendable {
    func load(
        _ reference: PhysicalDesignClockTimingModelReference,
        from artifactStore: any PhysicalDesignArtifactStore
    ) async throws -> PhysicalDesignClockTimingModel
}
