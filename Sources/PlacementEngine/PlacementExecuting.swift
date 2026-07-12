import Foundation
import XcircuitePackage
import PhysicalDesignCore

public protocol PlacementExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload>
}

