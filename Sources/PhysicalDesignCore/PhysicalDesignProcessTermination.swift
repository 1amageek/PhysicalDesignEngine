import Foundation

public enum PhysicalDesignProcessTermination: String, Sendable, Hashable, Codable {
    case completed
    case nonzeroExit
    case timedOut
    case cancelled
    case launchFailed
    case cancellationCheckFailed
}
