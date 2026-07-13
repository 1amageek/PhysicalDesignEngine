import Foundation
import CircuiteFoundation

public struct PhysicalDesignReviewResult: Sendable, Hashable, Codable {
    public var status: PhysicalDesignReviewGateStatus
    public var diagnostics: [DesignDiagnostic]
    public var packet: PhysicalDesignReviewPacket?
    public var decision: PhysicalDesignReviewDecision?

    public init(
        status: PhysicalDesignReviewGateStatus,
        diagnostics: [DesignDiagnostic] = [],
        packet: PhysicalDesignReviewPacket? = nil,
        decision: PhysicalDesignReviewDecision? = nil
    ) {
        self.status = status
        self.diagnostics = diagnostics
        self.packet = packet
        self.decision = decision
    }
}
