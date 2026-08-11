import CircuiteFoundation

public protocol PhysicalDesignArtifactReviewValidating: Sendable {
    func preparePacket(
        manifestReference: PhysicalDesignArtifactBinding,
        reviewScope: [String]
    ) async throws -> PhysicalDesignReviewPacket

    func validateCurrentArtifacts(
        _ packet: PhysicalDesignReviewPacket
    ) async -> [DesignDiagnostic]
}
