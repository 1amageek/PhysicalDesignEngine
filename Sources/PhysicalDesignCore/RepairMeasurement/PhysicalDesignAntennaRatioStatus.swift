import Foundation

public enum PhysicalDesignAntennaRatioStatus: String, Sendable, Hashable, Codable {
    case legacyUnverified
    case unavailableFromNativeRuleVerdict
    case sourceProcessLawMeasurements
}
