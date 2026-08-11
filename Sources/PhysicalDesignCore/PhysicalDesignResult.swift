import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation

/// Domain result for one physical-design stage execution.
public struct PhysicalDesignResult: Sendable, Hashable, Codable,
    ArtifactProducing, DiagnosticReporting, EvidenceProviding
{
    public let schemaVersion: Int
    public let runID: String
    public let status: PhysicalDesignExecutionStatus
    public let diagnostics: [DesignDiagnostic]
    public let artifactBindings: [PhysicalDesignArtifactBinding]
    public var artifacts: [ArtifactReference] { artifactBindings.map(\.reference) }
    public let provenance: ExecutionProvenance
    public let payload: PhysicalDesignPayload
    public let evidence: EvidenceManifest

    public init(
        schemaVersion: Int,
        runID: String,
        status: PhysicalDesignExecutionStatus,
        diagnostics: [DesignDiagnostic] = [],
        artifactBindings: [PhysicalDesignArtifactBinding] = [],
        provenance: ExecutionProvenance,
        payload: PhysicalDesignPayload
    ) throws {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.status = status
        self.diagnostics = diagnostics
        self.artifactBindings = artifactBindings
        self.provenance = provenance
        self.payload = payload
        self.evidence = try EvidenceManifest.contentAddressed(
            provenance: provenance,
            artifacts: artifactBindings.map(\.reference),
            digester: SHA256ContentDigester()
        )
    }
}
