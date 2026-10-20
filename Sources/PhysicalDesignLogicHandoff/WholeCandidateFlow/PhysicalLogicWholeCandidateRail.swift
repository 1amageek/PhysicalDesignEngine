/// Explicit untrusted numeric rail and actual source incidence.
public struct PhysicalLogicWholeCandidateRail: Sendable {
    public let sourceName: String
    public let zeroNode: String
    public let oneNode: String
    public let zeroVoltage: Double
    public let oneVoltage: Double
    public init(sourceName: String, zeroNode: String, oneNode: String, zeroVoltage: Double, oneVoltage: Double) {
        self.sourceName = sourceName; self.zeroNode = zeroNode; self.oneNode = oneNode
        self.zeroVoltage = zeroVoltage; self.oneVoltage = oneVoltage
    }
}
