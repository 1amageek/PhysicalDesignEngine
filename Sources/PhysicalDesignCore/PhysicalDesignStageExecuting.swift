import Foundation
import CircuiteFoundation
import XcircuitePackage

public protocol PhysicalDesignStageExecuting: Engine
where Request == PhysicalDesignRequest, Output == XcircuiteEngineResultEnvelope<PhysicalDesignPayload> {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload>
}
