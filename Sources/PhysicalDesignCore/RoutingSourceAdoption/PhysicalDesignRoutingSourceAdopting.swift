/// Explicitly checks a new source-bound input revision without publishing it.
public protocol PhysicalDesignRoutingSourceAdopting: Sendable {
    func adopt(_ input: PhysicalDesignRoutingSourceAdoptionInput,
               store: any PhysicalDesignArtifactStore) async throws -> PhysicalDesignRoutingSourceAdoptionResult
}
