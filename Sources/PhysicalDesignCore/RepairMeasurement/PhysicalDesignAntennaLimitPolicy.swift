/// Selects whether legacy scalar limits an explicitly supplied native law, or retained process laws govern repair.
public enum PhysicalDesignAntennaLimitPolicy: String, Sendable, Hashable, Codable {
    case legacyScalarLimit
    case nativeRuleVerdict
    case sourceProcessLaws
}
