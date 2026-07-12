import Foundation
import PhysicalDesignCore
import XcircuitePackage

public struct NativePlacementEngine: PlacementExecuting {
    private let executor: NativePhysicalDesignExecutor

    public init(
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-native.placement",
        implementationVersion: String = "1.0.0"
    ) {
        self.executor = NativePhysicalDesignExecutor(
            expectedStage: .placement,
            artifactStore: artifactStore,
            implementationID: implementationID,
            implementationVersion: implementationVersion
        )
    }

    public func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload> {
        try await executor.execute(request)
    }
}
