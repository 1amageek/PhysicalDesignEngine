import Foundation
import PhysicalDesignCore
import CircuiteFoundation

public struct NativePlacementEngine: PlacementExecuting {
    private let executor: NativePhysicalDesignExecutor

    public init(
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-native.placement",
        implementationVersion: String = NativePhysicalDesignExecutor.currentImplementationVersion
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
    ) async throws -> PhysicalDesignResult {
        try await executor.execute(request)
    }
}
