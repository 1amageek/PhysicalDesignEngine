import Foundation

public enum PhysicalDesignClockTimingModelError: Error, LocalizedError, Sendable, Hashable {
    case invalidModel(String)
    case sourceArtifactMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModel(let message):
            return "Clock timing model is invalid: \(message)"
        case .sourceArtifactMismatch(let source):
            return "Clock timing model source artifact does not match: \(source)"
        }
    }
}
