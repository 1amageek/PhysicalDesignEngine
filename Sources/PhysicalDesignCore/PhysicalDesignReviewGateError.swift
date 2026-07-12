import Foundation

public enum PhysicalDesignReviewGateError: Error, LocalizedError, Sendable, Hashable {
    case artifactReadFailed(String)
    case manifestDecodeFailed(String)
    case invalidManifest(String)

    public var errorDescription: String? {
        switch self {
        case .artifactReadFailed(let message):
            return "Physical design review artifact read failed: \(message)"
        case .manifestDecodeFailed(let message):
            return "Physical design review manifest decode failed: \(message)"
        case .invalidManifest(let message):
            return "Physical design review manifest is invalid: \(message)"
        }
    }
}
