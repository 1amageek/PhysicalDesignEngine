import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol PhysicalDFMExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult
}

