import Foundation
import XcircuitePackage
import PhysicalDesignCore

public protocol RoutingExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload>
}

