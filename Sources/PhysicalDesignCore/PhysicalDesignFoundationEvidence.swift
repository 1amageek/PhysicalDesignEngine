import CircuiteFoundation

/// Canonical evidence view exposed by the physical-design boundary.
///
/// Xcircuite keeps the domain-specific run manifest and review packet. This
/// value is the small shared representation consumed by flow coordinators and
/// agents without requiring them to depend on those compatibility models.
public struct PhysicalDesignFoundationEvidence: Sendable, Hashable, Codable,
    ArtifactProducing, EvidenceProviding, DiagnosticReporting
{
    public let evidence: EvidenceManifest
    public let diagnostics: [DesignDiagnostic]

    public var artifacts: [ArtifactReference] { evidence.artifacts }

    public init(
        provenance: ExecutionProvenance,
        artifacts: [ArtifactReference] = [],
        diagnostics: [DesignDiagnostic] = []
    ) {
        self.evidence = EvidenceManifest(
            provenance: provenance,
            artifacts: artifacts
        )
        self.diagnostics = diagnostics
    }

    public init(result: PhysicalDesignFoundationResult) {
        self.evidence = result.evidence
        self.diagnostics = result.diagnostics
    }
}
