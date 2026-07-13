import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol CTSExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult
}

