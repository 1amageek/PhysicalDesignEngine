import Foundation

public protocol PhysicalDesignStandardLayoutExporting: Sendable {
    func exportDEF(
        snapshot: PhysicalDesignSnapshot,
        request: PhysicalDesignRequest,
        artifactStore: any PhysicalDesignArtifactStore,
        limits: PhysicalDesignStandardLayoutExportLimits
    ) async throws -> Data
}
