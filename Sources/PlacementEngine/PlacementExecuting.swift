import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol PlacementExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult
}

