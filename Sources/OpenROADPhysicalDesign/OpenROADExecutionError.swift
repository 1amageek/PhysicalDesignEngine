import Foundation

public enum OpenROADExecutionError: Error, LocalizedError, Sendable, Hashable {
    case productionConfigurationMissing
    case unsupportedBackend(String)
    case executableUnavailable(String)
    case executableNotRegularFile(String)
    case executableIntegrityMismatch(String)
    case toolVersionProbeFailed(String)
    case toolVersionMismatch(expected: String, observed: String)
    case inputArtifactInvalid(String)
    case processFailed(exitCode: Int32)
    case outputDEFUnavailable
    case outputDEFInvalid
    case stageCompletionEvidenceInvalid(String)
    case outputTopCellMismatch(expected: String, actual: String)
    case scratchWorkspaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .productionConfigurationMissing:
            return "A production physical-design configuration is required."
        case .unsupportedBackend(let backendID):
            return "Unsupported production physical-design backend: \(backendID)."
        case .executableUnavailable(let path):
            return "OpenROAD executable is unavailable or not executable: \(path)."
        case .executableNotRegularFile(let path):
            return "OpenROAD executable is not a regular file: \(path)."
        case .executableIntegrityMismatch(let reason):
            return "OpenROAD executable integrity check failed: \(reason)."
        case .toolVersionProbeFailed(let reason):
            return "OpenROAD version probe failed: \(reason)."
        case .toolVersionMismatch(let expected, let observed):
            return "OpenROAD version mismatch. Expected \(expected), observed \(observed)."
        case .inputArtifactInvalid(let reason):
            return "OpenROAD input artifact is invalid: \(reason)."
        case .processFailed(let exitCode):
            return "OpenROAD exited with status \(exitCode)."
        case .outputDEFUnavailable:
            return "OpenROAD completed without producing the required output DEF."
        case .outputDEFInvalid:
            return "OpenROAD output DEF could not be represented by the canonical physical snapshot."
        case .stageCompletionEvidenceInvalid(let reason):
            return "OpenROAD stage completion evidence is invalid: \(reason)."
        case .outputTopCellMismatch(let expected, let actual):
            return "OpenROAD output top cell \(actual) does not match \(expected)."
        case .scratchWorkspaceFailed(let reason):
            return "OpenROAD scratch workspace failed: \(reason)."
        }
    }
}
