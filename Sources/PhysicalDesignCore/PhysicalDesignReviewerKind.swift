import Foundation

public enum PhysicalDesignReviewerKind: String, Sendable, Hashable, Codable {
    case human
    case agent
    case cli
    case system
}
