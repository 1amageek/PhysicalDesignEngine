import Foundation
import XcircuitePackage

public struct PhysicalDesignReviewResult: Sendable, Hashable, Codable {
    public var status: PhysicalDesignReviewGateStatus
    public var diagnostics: [XcircuiteEngineDiagnostic]
    public var packet: PhysicalDesignReviewPacket?
    public var decision: PhysicalDesignReviewDecision?

    public init(
        status: PhysicalDesignReviewGateStatus,
        diagnostics: [XcircuiteEngineDiagnostic] = [],
        packet: PhysicalDesignReviewPacket? = nil,
        decision: PhysicalDesignReviewDecision? = nil
    ) {
        self.status = status
        self.diagnostics = diagnostics
        self.packet = packet
        self.decision = decision
    }
}
