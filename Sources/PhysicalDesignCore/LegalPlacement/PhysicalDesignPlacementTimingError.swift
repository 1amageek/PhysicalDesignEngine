import Foundation
import STAEngine
import TimingCore
import PEXParsers

public enum PhysicalDesignPlacementTimingError: Error, Sendable, LocalizedError {
    case invalidProfile(String)
    case logicalMismatch(String)
    case unavailableTiming(String)
    case resourceLimit(String)
    case preparation(STAPreparationError)
    case execution(STAExecutionError)
    case source(LibertySourceError)
    case characterization(TimingCharacterizationError)
    case parasiticProjection(SPEFWriterError)
    case deadline
    public var code: String {
        switch self {
        case .invalidProfile: "placement_timing_profile_invalid"
        case .logicalMismatch: "placement_timing_graph_mismatch"
        case .unavailableTiming, .preparation, .execution, .source, .characterization, .parasiticProjection: "placement_timing_unavailable"
        case .resourceLimit: "placement_timing_resource_limit"
        case .deadline: "placement_timing_deadline"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let reason), .logicalMismatch(let reason), .unavailableTiming(let reason), .resourceLimit(let reason): reason
        case .preparation(let cause): "Characterized STA preparation failed: \(cause)"
        case .execution(let cause): "Characterized STA execution failed: \(cause)"
        case .source(let cause): "Strict source characterization failed: \(cause)"
        case .characterization(let cause): "Strict operating-point characterization failed: \(cause)"
        case .parasiticProjection(let cause): "Source RC projection cannot preserve its SPEF input: \(cause)"
        case .deadline: "The cumulative timing-driven placement deadline expired."
        }
    }
}
