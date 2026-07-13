import CircuiteFoundation
import Foundation

/// Domain result for one physical-design stage execution.
public struct PhysicalDesignResult: Sendable, Hashable, Codable,
    ArtifactProducing, DiagnosticReporting, EvidenceProviding
{
    public let schemaVersion: Int
    public let runID: String
    public let status: PhysicalDesignExecutionStatus
    public let diagnostics: [DesignDiagnostic]
    public let artifacts: [ArtifactReference]
    public let provenance: ExecutionProvenance
    public let payload: PhysicalDesignPayload

    public init(
        schemaVersion: Int,
        runID: String,
        status: PhysicalDesignExecutionStatus,
        diagnostics: [DesignDiagnostic] = [],
        artifacts: [ArtifactReference] = [],
        metadata: ExecutionProvenance,
        payload: PhysicalDesignPayload
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.status = status
        self.diagnostics = diagnostics
        self.artifacts = artifacts
        self.provenance = metadata
        self.payload = payload
    }

    public var evidence: EvidenceManifest {
        EvidenceManifest(provenance: provenance, artifacts: artifacts)
    }
}
