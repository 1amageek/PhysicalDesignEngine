import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol RoutingExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult
}

