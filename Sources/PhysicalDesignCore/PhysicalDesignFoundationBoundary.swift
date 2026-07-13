import CircuiteFoundation
import Foundation

/// Foundation projections for physical-design results.
public typealias PhysicalDesignFoundationExecutionStatus = PhysicalDesignExecutionStatus
public typealias PhysicalDesignFoundationResult = PhysicalDesignResult

/// The physical-design stage executor already uses Foundation types directly;
/// this protocol is retained as a descriptive capability for host composition.
public protocol PhysicalDesignFoundationExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignResult {}

public enum PhysicalDesignFoundationBoundaryError: Error, LocalizedError, Sendable, Hashable {
    case invalidArtifactID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArtifactID(let value):
            return "Physical-design artifact ID is invalid: \(value)"
        }
    }
}

/// Identity-preserving projections for callers that already hold canonical
/// Foundation references. No legacy conversion or hidden hashing occurs.
public enum PhysicalDesignFoundationArtifactConversion {
    public static func references(from references: [ArtifactReference]) throws -> [ArtifactReference] {
        references
    }

    public static func reference(from reference: ArtifactReference) throws -> ArtifactReference {
        reference
    }
}
