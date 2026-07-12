import Foundation
import XcircuitePackage
import PhysicalDesignCore

public protocol FloorplanExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload>
}

