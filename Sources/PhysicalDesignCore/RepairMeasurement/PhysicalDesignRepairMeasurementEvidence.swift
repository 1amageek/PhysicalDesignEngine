import CircuiteFoundation
import DRCCore
import DRCNative
import Foundation

public struct PhysicalDesignRepairMeasurementEvidence: Sendable, Hashable, Codable {
    public struct Check: Sendable, Hashable, Codable {
        public let ruleIDs: [String]
        public let beforeLayout: NativeDRCLayout
        public let afterLayout: NativeDRCLayout
        public let before: DRCExecutionResult
        public let after: DRCExecutionResult
        public init(ruleIDs: [String], beforeLayout: NativeDRCLayout, afterLayout: NativeDRCLayout,
                    before: DRCExecutionResult, after: DRCExecutionResult) {
            self.ruleIDs = ruleIDs; self.beforeLayout = beforeLayout; self.afterLayout = afterLayout
            self.before = before; self.after = after
        }
    }
    public let profile: ArtifactReference
    public let beforeSnapshotDigest: ContentDigest
    public let afterSnapshotDigest: ContentDigest
    public let targetNetIDs: [String]
    public let targetGatePinIDs: [String]
    public let checks: [Check]
    public init(profile: ArtifactReference, beforeSnapshotDigest: ContentDigest, afterSnapshotDigest: ContentDigest,
                targetNetIDs: [String], targetGatePinIDs: [String], checks: [Check]) {
        self.profile = profile; self.beforeSnapshotDigest = beforeSnapshotDigest; self.afterSnapshotDigest = afterSnapshotDigest
        self.targetNetIDs = targetNetIDs; self.targetGatePinIDs = targetGatePinIDs; self.checks = checks
    }
}
