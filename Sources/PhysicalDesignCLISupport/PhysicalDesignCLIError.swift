import Foundation

public enum PhysicalDesignCLIError: Error, LocalizedError, Sendable, Hashable {
    case missingValue(String)
    case unknownOption(String)

    public var code: String {
        switch self {
        case .missingValue:
            return "missing_option_value"
        case .unknownOption:
            return "unknown_option"
        }
    }

    public var actions: [String] {
        ["run_physical_design_help"]
    }

    public var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Option \(option) requires a value."
        case .unknownOption(let option):
            return "Unknown option \(option)."
        }
    }
}
