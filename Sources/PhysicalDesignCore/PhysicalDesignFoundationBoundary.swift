import Foundation
@_exported import CircuiteFoundation
import XcircuitePackage

/// Domain execution status exposed at the Foundation boundary.
public enum PhysicalDesignFoundationExecutionStatus: String, Sendable, Hashable, Codable {
    case completed
    case failed
    case blocked
    case cancelled
}

/// Foundation-native physical-design execution result.
public struct PhysicalDesignFoundationResult: Sendable, Hashable, Codable,
    ArtifactProducing, DiagnosticReporting, EvidenceProviding
{
    public let runID: String
    public let stage: PhysicalDesignStage
    public let status: PhysicalDesignFoundationExecutionStatus
    public let changedObjectCount: Int
    public let candidateActions: [String]
    public let metrics: [PhysicalDesignMetric]
    public let artifacts: [ArtifactReference]
    public let diagnostics: [DesignDiagnostic]
    public let evidence: EvidenceManifest

    public init(
        runID: String,
        stage: PhysicalDesignStage,
        status: PhysicalDesignFoundationExecutionStatus,
        changedObjectCount: Int = 0,
        candidateActions: [String] = [],
        metrics: [PhysicalDesignMetric] = [],
        artifacts: [ArtifactReference] = [],
        diagnostics: [DesignDiagnostic] = [],
        provenance: ExecutionProvenance
    ) {
        self.runID = runID
        self.stage = stage
        self.status = status
        self.changedObjectCount = changedObjectCount
        self.candidateActions = candidateActions
        self.metrics = metrics
        self.artifacts = artifacts
        self.diagnostics = diagnostics
        self.evidence = EvidenceManifest(provenance: provenance, artifacts: artifacts)
    }
}

/// Asynchronous engine seam for callers that use the shared Foundation
/// vocabulary. Xcircuite's legacy request/result models remain available for
/// project and run lifecycle integration during the migration.
public protocol PhysicalDesignFoundationExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignFoundationResult {}

/// Typed errors raised while converting legacy Xcircuite references into the
/// Foundation artifact model.
public enum PhysicalDesignFoundationBoundaryError: Error, LocalizedError, Sendable, Hashable {
    case missingDigest(String)
    case missingByteCount(String)
    case invalidByteCount(String)
    case invalidArtifactID(String)

    public var errorDescription: String? {
        switch self {
        case .missingDigest(let path):
            return "Physical-design artifact has no verified SHA-256 digest: \(path)"
        case .missingByteCount(let path):
            return "Physical-design artifact has no verified byte count: \(path)"
        case .invalidByteCount(let path):
            return "Physical-design artifact has an invalid byte count: \(path)"
        case .invalidArtifactID(let value):
            return "Physical-design artifact ID cannot be converted to a stable Foundation identity: \(value)"
        }
    }
}

/// Conversion helpers for the compatibility artifact references emitted by
/// the existing Xcircuite-backed executor.
public enum PhysicalDesignFoundationArtifactConversion {
    public static func references(
        from legacyReferences: [XcircuiteFileReference]
    ) throws -> [ArtifactReference] {
        try legacyReferences.map(reference(from:))
    }

    public static func reference(
        from legacyReference: XcircuiteFileReference
    ) throws -> ArtifactReference {
        guard let sha256 = legacyReference.sha256 else {
            throw PhysicalDesignFoundationBoundaryError.missingDigest(legacyReference.path)
        }
        guard let byteCount = legacyReference.byteCount else {
            throw PhysicalDesignFoundationBoundaryError.missingByteCount(legacyReference.path)
        }
        guard byteCount >= 0 else {
            throw PhysicalDesignFoundationBoundaryError.invalidByteCount(legacyReference.path)
        }

        let artifactID = try makeArtifactID(
            legacyID: legacyReference.artifactID,
            path: legacyReference.path,
            digest: sha256
        )
        let location = try ArtifactLocation(workspaceRelativePath: legacyReference.path)
        let kind = try ArtifactKind(rawValue: legacyReference.kind.rawValue)
        let format = try foundationFormat(for: legacyReference.format)
        let digest = try ContentDigest(algorithm: .sha256, hexadecimalValue: sha256)
        return ArtifactReference(
            id: artifactID,
            locator: ArtifactLocator(location: location, kind: kind, format: format),
            digest: digest,
            byteCount: UInt64(byteCount)
        )
    }

    private static func makeArtifactID(
        legacyID: String?,
        path: String,
        digest: String
    ) throws -> ArtifactID {
        guard let legacyID else {
            return ArtifactID(stableKey: "physical-design:\(path):\(digest)")
        }
        let normalized = legacyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw PhysicalDesignFoundationBoundaryError.invalidArtifactID(legacyID)
        }
        do {
            return try ArtifactID(rawValue: normalized)
        } catch {
            throw PhysicalDesignFoundationBoundaryError.invalidArtifactID(normalized)
        }
    }

    private static func foundationFormat(
        for format: XcircuiteFileFormat
    ) throws -> ArtifactFormat {
        switch format {
        case .json:
            return .json
        case .spice:
            return .spice
        case .systemVerilog:
            return .systemVerilog
        case .verilog:
            return .verilog
        case .oasis:
            return .oasis
        case .gdsii:
            return .gdsii
        case .lef:
            return .lef
        case .def:
            return .def
        case .spef:
            return .spef
        case .dspf:
            return .dspf
        case .liberty:
            return .liberty
        case .sdf:
            return .sdf
        case .vcd:
            return .vcd
        default:
            return try ArtifactFormat(
                rawValue: format.rawValue.lowercased().replacingOccurrences(of: "_", with: "-")
            )
        }
    }
}

extension PhysicalDesignRequest {
    /// Returns the stable Foundation identity for the physical top cell.
    public func designObjectReference() throws -> DesignObjectReference {
        let identifier = inputLayout?.topCell ?? initialSnapshot?.topCell ?? design.topDesignName
        return try DesignObjectReference(kind: .cell, identifier: identifier)
    }
}
