import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol FloorplanExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult
}

