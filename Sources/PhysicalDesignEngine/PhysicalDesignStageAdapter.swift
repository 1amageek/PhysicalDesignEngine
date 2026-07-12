import Foundation
import XcircuitePackage
import PhysicalDesignCore

public struct PhysicalDesignStageAdapter<Executor: PhysicalDesignStageExecuting>: Sendable {
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload> {
        try await executor.execute(request)
    }
}
