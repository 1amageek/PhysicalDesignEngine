import Foundation
import XcircuitePackage
import PhysicalDesignCore

public protocol CTSExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload>
}

