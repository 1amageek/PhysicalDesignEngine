import Foundation

public enum PhysicalDesignStoreError: Error, LocalizedError, Sendable, Hashable {
    case invalidPath(String)
    case pathAlreadyExists(String)
    case readFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "Physical design artifact path is invalid: \(path)"
        case .pathAlreadyExists(let path):
            return "Physical design artifact path is immutable and already exists: \(path)"
        case .readFailed(let message):
            return "Physical design artifact read failed: \(message)"
        case .writeFailed(let message):
            return "Physical design artifact write failed: \(message)"
        }
    }
}
