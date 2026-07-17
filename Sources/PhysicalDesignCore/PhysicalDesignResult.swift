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
    public let evidence: EvidenceManifest

    public init(
        schemaVersion: Int,
        runID: String,
        status: PhysicalDesignExecutionStatus,
        diagnostics: [DesignDiagnostic] = [],
        artifacts: [ArtifactReference] = [],
        provenance: ExecutionProvenance,
        payload: PhysicalDesignPayload
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.status = status
        self.diagnostics = diagnostics
        self.artifacts = artifacts
        self.provenance = provenance
        self.payload = payload
        self.evidence = EvidenceManifest(provenance: provenance, artifacts: artifacts)
    }
}
