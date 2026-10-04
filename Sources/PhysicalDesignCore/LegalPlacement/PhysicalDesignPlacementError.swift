import Foundation

enum PhysicalDesignPlacementError: Error, LocalizedError {
    case invalidLockedCell(String)
    case capacity(String)
    case candidateBudget
    case arithmeticOverflow

    var code: String {
        switch self {
        case .invalidLockedCell: "locked_cell_placement_invalid"
        case .capacity: "placement_capacity_exceeded"
        case .candidateBudget: "placement_candidate_budget_exceeded"
        case .arithmeticOverflow: "placement_arithmetic_overflow"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidLockedCell(let id): "Locked cell \(id) requires a compatible, placed, non-overlapping location inside the core and outside blockages."
        case .capacity(let id): "No legal row candidate is available for cell \(id) under the retained deterministic allocation order."
        case .candidateBudget: "Native placement exhausted the caller's candidate evaluation ceiling."
        case .arithmeticOverflow: "Native placement geometry or structural candidate budget exceeds the representable range."
        }
    }
}
