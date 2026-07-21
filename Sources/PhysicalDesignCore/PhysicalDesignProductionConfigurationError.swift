import Foundation

public enum PhysicalDesignProductionConfigurationError: Error, LocalizedError, Sendable, Hashable {
    case invalidBackendID
    case invalidExecutablePath
    case invalidToolID
    case invalidExpectedVersion
    case invalidVersionArguments
    case invalidExecutableDigest
    case invalidExecutableByteCount
    case invalidCornerID
    case invalidTimeout
    case missingTechnologyLEF
    case missingCellLEF
    case missingLibertyLibrary
    case invalidArtifact(String)
    case duplicateArtifact(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBackendID:
            return "Production backend ID must be a non-empty identifier without control characters."
        case .invalidExecutablePath:
            return "Production executable path is invalid."
        case .invalidToolID:
            return "Production tool ID is invalid."
        case .invalidExpectedVersion:
            return "Production tool version is invalid."
        case .invalidVersionArguments:
            return "Production tool version probe arguments are invalid."
        case .invalidExecutableDigest:
            return "Production executable must be bound by a SHA-256 digest."
        case .invalidExecutableByteCount:
            return "Production executable byte count must be positive."
        case .invalidCornerID:
            return "Production corner ID is invalid."
        case .invalidTimeout:
            return "Production process timeout must be positive finite seconds."
        case .missingTechnologyLEF:
            return "At least one technology LEF artifact is required."
        case .missingCellLEF:
            return "At least one cell LEF artifact is required."
        case .missingLibertyLibrary:
            return "At least one Liberty artifact is required."
        case .invalidArtifact(let reason):
            return "Production artifact is invalid: \(reason)"
        case .duplicateArtifact(let path):
            return "Production artifact is duplicated: \(path)"
        }
    }
}
