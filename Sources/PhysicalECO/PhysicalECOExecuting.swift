import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol PhysicalECOExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult
}

