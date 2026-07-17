import Foundation
import CircuiteFoundation

public struct PhysicalDesignArtifactReviewValidator: PhysicalDesignArtifactReviewValidating {
    public let artifactStore: any PhysicalDesignArtifactStore

    private let codec: PhysicalDesignJSONCodec
    private let hasher: SHA256ContentDigester

    public init(artifactStore: any PhysicalDesignArtifactStore) {
        self.artifactStore = artifactStore
        self.codec = PhysicalDesignJSONCodec()
        self.hasher = SHA256ContentDigester()
    }

    public func preparePacket(
        manifestReference: ArtifactReference,
        reviewScope: [String] = ["proposed_layout", "design_diff", "implementation_configuration"]
    ) async throws -> PhysicalDesignReviewPacket {
        guard !reviewScope.isEmpty,
              Set(reviewScope).count == reviewScope.count,
              !reviewScope.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PhysicalDesignArtifactReviewError.invalidManifest(
                "review scope must contain unique, non-empty values"
            )
        }
        let data: Data
        do {
            data = try await artifactStore.read(manifestReference)
        } catch {
            throw PhysicalDesignArtifactReviewError.artifactReadFailed(error.localizedDescription)
        }
        let expectedManifestDigest = manifestReference.digest.hexadecimalValue
        let expectedManifestByteCount = manifestReference.byteCount
        guard !expectedManifestDigest.isEmpty else {
            throw PhysicalDesignArtifactReviewError.artifactReadFailed(
                "\(manifestReference.path): manifest reference lacks complete integrity metadata"
            )
        }
        let actualManifestDigest = try hasher
            .digest(data: data, using: manifestReference.digest.algorithm)
            .hexadecimalValue
        guard expectedManifestDigest == actualManifestDigest else {
            throw PhysicalDesignArtifactReviewError.artifactReadFailed(
                "\(manifestReference.path): digest does not match the manifest reference"
            )
        }
        guard UInt64(data.count) == expectedManifestByteCount else {
            throw PhysicalDesignArtifactReviewError.artifactReadFailed(
                "\(manifestReference.path): byte count does not match the manifest reference"
            )
        }
        let manifest: PhysicalDesignRunManifest
        do {
            manifest = try codec.decode(PhysicalDesignRunManifest.self, from: data)
        } catch {
            throw PhysicalDesignArtifactReviewError.manifestDecodeFailed(error.localizedDescription)
        }
        guard manifestReference.format == .json else {
            throw PhysicalDesignArtifactReviewError.invalidManifest(
                "review manifest reference must use JSON format"
            )
        }
        let manifestDiagnostics = manifest.validationDiagnostics()
        guard manifestDiagnostics.isEmpty else {
            throw PhysicalDesignArtifactReviewError.invalidManifest(
                manifestDiagnostics.joined(separator: "; ")
            )
        }
        guard manifest.status == .completed,
              let proposedLayout = manifest.proposedLayout,
              let designDiff = manifest.designDiff else {
            throw PhysicalDesignArtifactReviewError.invalidManifest(
                "completed run does not expose proposed layout and design diff"
            )
        }

        var artifactDigests: [String: String] = [:]
        for artifact in manifest.artifacts {
            let artifactData: Data
            do {
                artifactData = try await artifactStore.read(artifact)
            } catch {
                throw PhysicalDesignArtifactReviewError.artifactReadFailed(error.localizedDescription)
            }
            let expectedDigest = artifact.digest.hexadecimalValue
            guard !expectedDigest.isEmpty else {
                throw PhysicalDesignArtifactReviewError.artifactReadFailed(
                    "\(artifact.path): artifact reference lacks complete integrity metadata"
                )
            }
            let digest = try hasher
                .digest(data: artifactData, using: artifact.digest.algorithm)
                .hexadecimalValue
            guard expectedDigest == digest else {
                throw PhysicalDesignArtifactReviewError.artifactReadFailed(
                    "\(artifact.path): digest does not match the artifact reference"
                )
            }
            guard UInt64(artifactData.count) == artifact.byteCount else {
                throw PhysicalDesignArtifactReviewError.artifactReadFailed(
                    "\(artifact.path): byte count does not match the artifact reference"
                )
            }
            artifactDigests[artifact.path] = digest
        }

        guard artifactDigests[proposedLayout.layoutArtifact.path] == proposedLayout.layoutDigest else {
            throw PhysicalDesignArtifactReviewError.invalidManifest(
                "proposed layout digest does not match its immutable artifact"
            )
        }
        guard artifactDigests[designDiff.path] != nil else {
            throw PhysicalDesignArtifactReviewError.invalidManifest(
                "design diff is not present in the immutable artifact set"
            )
        }

        let packet = PhysicalDesignReviewPacket(
            runID: manifest.runID,
            stage: manifest.stage,
            manifest: manifest,
            manifestReference: manifestReference,
            manifestDigest: actualManifestDigest,
            baseLayout: manifest.baseLayout,
            proposedLayout: proposedLayout,
            designDiff: designDiff,
            artifactDigests: artifactDigests,
            reviewScope: reviewScope
        )
        let packetDiagnostics = packet.validationDiagnostics()
        guard packetDiagnostics.isEmpty else {
            throw PhysicalDesignArtifactReviewError.invalidManifest(
                packetDiagnostics.joined(separator: "; ")
            )
        }
        return packet
    }

    public func validateCurrentArtifacts(
        _ packet: PhysicalDesignReviewPacket
    ) async -> [DesignDiagnostic] {
        let packetDiagnostics = packet.validationDiagnostics().map {
            diagnostic(
                code: "physical_design_review_packet_invalid",
                summary: $0,
                actions: ["prepare_a_new_physical_design_review_packet"]
            )
        }
        guard packetDiagnostics.isEmpty else {
            return packetDiagnostics
        }

        do {
            let currentPacket = try await preparePacket(
                manifestReference: packet.manifestReference,
                reviewScope: packet.reviewScope
            )
            var differences: [String] = []
            if currentPacket.manifestReference != packet.manifestReference { differences.append("manifest_reference") }
            if currentPacket.manifest != packet.manifest { differences.append("manifest") }
            if currentPacket.runID != packet.runID { differences.append("run_id") }
            if currentPacket.stage != packet.stage { differences.append("stage") }
            if currentPacket.manifestDigest != packet.manifestDigest { differences.append("manifest_digest") }
            if currentPacket.proposedLayout != packet.proposedLayout { differences.append("proposed_layout") }
            if currentPacket.baseLayout != packet.baseLayout { differences.append("base_layout") }
            if currentPacket.designDiff != packet.designDiff { differences.append("design_diff") }
            if currentPacket.artifactDigests != packet.artifactDigests { differences.append("artifact_digests") }
            if currentPacket.reviewScope != packet.reviewScope { differences.append("review_scope") }
            guard differences.isEmpty else {
                return [diagnostic(
                    code: "physical_design_review_artifacts_stale",
                    summary: "Reviewed physical-design artifacts changed after packet creation: " + differences.joined(separator: ", ") + ".",
                    actions: ["prepare_a_new_physical_design_review_packet"]
                )]
            }
            return []
        } catch {
            return [diagnostic(
                code: "physical_design_review_artifacts_unavailable",
                summary: "Reviewed physical-design artifacts could not be revalidated: \(error.localizedDescription)",
                actions: ["restore_review_artifacts", "prepare_a_new_physical_design_review_packet"]
            )]
        }
    }

    private func diagnostic(
        code: String,
        summary: String,
        actions: [String]
    ) -> DesignDiagnostic {
        DesignDiagnostic(
            code: .trusted(code),
            severity: .error,
            summary: summary,
            suggestedActions: actions.map { SuggestedAction(code: $0, summary: $0) }
        )
    }
}
