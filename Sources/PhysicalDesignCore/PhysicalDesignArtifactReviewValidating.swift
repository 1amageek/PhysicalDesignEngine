import CircuiteFoundation

public protocol PhysicalDesignArtifactReviewValidating: Sendable {
    func preparePacket(
        manifestReference: ArtifactReference,
        reviewScope: [String]
    ) async throws -> PhysicalDesignReviewPacket

    func validateCurrentArtifacts(
        _ packet: PhysicalDesignReviewPacket
    ) async -> [DesignDiagnostic]
}
