import Foundation

public enum PhysicalDesignClockTimingModelError: Error, LocalizedError, Sendable, Hashable {
    case invalidModel(String)
    case sourceArtifactMismatch(String)
    case unsupportedPathLength(Int64)
    case missingCellDelay(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModel(let message):
            return "Clock timing model is invalid: \(message)"
        case .sourceArtifactMismatch(let source):
            return "Clock timing model source artifact does not match: \(source)"
        case .unsupportedPathLength(let lengthDBU):
            return "Clock path length \(lengthDBU) DBU is outside the characterized range."
        case .missingCellDelay(let master):
            return "Clock timing model does not characterize cell master \(master)."
        }
    }
}
