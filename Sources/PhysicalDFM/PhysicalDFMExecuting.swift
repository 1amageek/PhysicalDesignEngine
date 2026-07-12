import Foundation
import XcircuitePackage
import PhysicalDesignCore

public protocol PhysicalDFMExecuting: Sendable {
    func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload>
}

