import Foundation

public enum PhysicalDesignArtifactReviewError: Error, LocalizedError, Sendable, Hashable {
    case artifactReadFailed(String)
    case manifestDecodeFailed(String)
    case invalidManifest(String)

    public var errorDescription: String? {
        switch self {
        case .artifactReadFailed(let message):
            return "Physical design artifact review read failed: \(message)"
        case .manifestDecodeFailed(let message):
            return "Physical design artifact review manifest decode failed: \(message)"
        case .invalidManifest(let message):
            return "Physical design artifact review manifest is invalid: \(message)"
        }
    }
}
