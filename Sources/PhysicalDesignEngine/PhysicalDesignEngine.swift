import Foundation
import PhysicalDesignCore
import CircuiteFoundation
import OpenROADPhysicalDesign

public struct PhysicalDesignEngine: PhysicalDesignStageExecuting {
    public let artifactStore: any PhysicalDesignArtifactStore

    private let executor: NativePhysicalDesignExecutor
    private let openROADExecutor: OpenROADPhysicalDesignExecutor

    public init(
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-native",
        implementationVersion: String = "1.0.0"
    ) {
        self.artifactStore = artifactStore
        self.executor = NativePhysicalDesignExecutor(
            artifactStore: artifactStore,
            implementationID: implementationID,
            implementationVersion: implementationVersion
        )
        self.openROADExecutor = OpenROADPhysicalDesignExecutor(
            artifactStore: artifactStore
        )
    }

    public func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult {
        switch request.executionIntent {
        case .geometrySmoke, .characterizedTiming:
            try await executor.execute(request)
        case .productionImplementation:
            try await openROADExecutor.execute(request)
        }
    }
}
