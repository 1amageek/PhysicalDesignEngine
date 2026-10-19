import PhysicalDesignCore

/// Untrusted persisted references; only checked reload reconstructs functional authority.
public struct PhysicalLogicCheckedCandidateArtifacts: Sendable, Hashable, Codable {
    public let candidate: PhysicalDesignReference
    public let netlist: PhysicalDesignArtifactBinding
    public let certificate: PhysicalDesignArtifactBinding
    public let manifest: PhysicalDesignArtifactBinding

    public init(candidate: PhysicalDesignReference, netlist: PhysicalDesignArtifactBinding,
                certificate: PhysicalDesignArtifactBinding, manifest: PhysicalDesignArtifactBinding) {
        self.candidate = candidate; self.netlist = netlist
        self.certificate = certificate; self.manifest = manifest
    }
}
