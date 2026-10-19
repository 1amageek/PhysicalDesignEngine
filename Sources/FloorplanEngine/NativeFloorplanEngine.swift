import Foundation
import PhysicalDesignCore
import CircuiteFoundation

public struct NativeFloorplanEngine: FloorplanExecuting {
    private let executor: NativePhysicalDesignExecutor

    public init(
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-native.floorplan",
        implementationVersion: String = NativePhysicalDesignExecutor.currentImplementationVersion
    ) {
        self.executor = NativePhysicalDesignExecutor(
            allowedStages: [.floorplan, .powerPlanning],
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
