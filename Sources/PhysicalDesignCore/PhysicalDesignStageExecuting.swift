import Foundation
import CircuiteFoundation
import CircuiteFoundation

public protocol PhysicalDesignStageExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignResult {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult
}
