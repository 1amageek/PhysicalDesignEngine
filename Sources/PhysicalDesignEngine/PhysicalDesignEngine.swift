import Foundation
import PhysicalDesignCore
import CircuiteFoundation

public struct PhysicalDesignEngine: PhysicalDesignStageExecuting {
    public let artifactStore: any PhysicalDesignArtifactStore

    private let executor: NativePhysicalDesignExecutor

    public init(
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-native",
        implementationVersion: String = NativePhysicalDesignExecutor.currentImplementationVersion
    ) {
        self.artifactStore = artifactStore
        self.executor = NativePhysicalDesignExecutor(
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
