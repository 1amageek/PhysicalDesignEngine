import Foundation

enum PhysicalDesignTechnologyError: Error, Sendable, LocalizedError {
    case invalid(String)
    case unsupported(String)

    var diagnosticCode: String {
        switch self {
        case .invalid: "physical_technology_invalid"
        case .unsupported: "physical_technology_unsupported"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid(let reason), .unsupported(let reason): reason
        }
    }
}
