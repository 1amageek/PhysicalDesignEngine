import Foundation
import PhysicalDesignCore
import CircuiteFoundation

public struct NativePhysicalECOEngine: PhysicalECOExecuting {
    private let executor: NativePhysicalDesignExecutor

    public init(
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-native.eco",
        implementationVersion: String = NativePhysicalDesignExecutor.currentImplementationVersion
    ) {
        self.executor = NativePhysicalDesignExecutor(
            allowedStages: [.timingECO, .drcRepair],
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
