import Foundation

public enum PhysicalDesignExecutionStatus: String, Sendable, Hashable, Codable {
    case completed
    case failed
    case blocked
    case cancelled
}
