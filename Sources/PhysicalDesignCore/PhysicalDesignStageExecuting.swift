import Foundation
import XcircuitePackage

public protocol PhysicalDesignStageExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload>
}
