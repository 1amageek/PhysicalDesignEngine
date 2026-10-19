import Foundation

public struct PhysicalDesignHotspotConstraint: Sendable, Hashable, Codable {
    public enum Predicate: Sendable, Hashable, Codable {
        case metalSpacing(ruleID: String, targetNetIDs: [String])
        case fillDensity(ruleID: String, targetFillIDs: [String])
        case viaCutSpacing(ruleID: String, targetViaIDs: [String])

        public var ruleID: String {
            switch self {
            case .metalSpacing(let id, _), .fillDensity(let id, _), .viaCutSpacing(let id, _): return id
            }
        }
    }
    public let hotspotID: String
    public let predicate: Predicate
    public init(hotspotID: String, predicate: Predicate) { self.hotspotID = hotspotID; self.predicate = predicate }
}
