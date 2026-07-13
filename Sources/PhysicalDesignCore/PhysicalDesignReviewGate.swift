import Foundation
import XcircuitePackage

public struct PhysicalDesignReviewGate: PhysicalDesignReviewGating {
    public let artifactStore: any PhysicalDesignArtifactStore

    private let codec: PhysicalDesignJSONCodec
    private let hasher: XcircuiteHasher

    public init(artifactStore: any PhysicalDesignArtifactStore) {
        self.artifactStore = artifactStore
        self.codec = PhysicalDesignJSONCodec()
        self.hasher = XcircuiteHasher()
    }

    public func prepareReview(
        manifestReference: XcircuiteFileReference,
        decisionScope: [String] = ["proposed_layout", "design_diff", "implementation_configuration"]
    ) async throws -> PhysicalDesignReviewPacket {
        let data: Data
        do {
            data = try await artifactStore.read(manifestReference)
        } catch {
            throw PhysicalDesignReviewGateError.artifactReadFailed(error.localizedDescription)
        }
        guard let expectedManifestDigest = manifestReference.sha256,
              !expectedManifestDigest.isEmpty,
              let expectedManifestByteCount = manifestReference.byteCount,
              expectedManifestByteCount >= 0 else {
            throw PhysicalDesignReviewGateError.artifactReadFailed(
                "\(manifestReference.path): manifest reference lacks complete integrity metadata"
            )
        }
        let actualManifestDigest = hasher.sha256(data: data)
        if expectedManifestDigest != actualManifestDigest {
            throw PhysicalDesignReviewGateError.artifactReadFailed(
                "\(manifestReference.path): SHA-256 digest does not match the manifest reference"
            )
        }
        if Int64(data.count) != expectedManifestByteCount {
            throw PhysicalDesignReviewGateError.artifactReadFailed(
                "\(manifestReference.path): byte count does not match the manifest reference"
            )
        }
        let manifest: PhysicalDesignRunManifest
        do {
            manifest = try codec.decode(PhysicalDesignRunManifest.self, from: data)
        } catch {
            throw PhysicalDesignReviewGateError.manifestDecodeFailed(error.localizedDescription)
        }
        guard manifestReference.format == .json else {
            throw PhysicalDesignReviewGateError.invalidManifest("review manifest reference must use JSON format")
        }
        if let producedByRunID = manifestReference.producedByRunID, producedByRunID != manifest.runID {
            throw PhysicalDesignReviewGateError.invalidManifest("review manifest reference is produced by a different run")
        }
        let manifestDiagnostics = manifest.validationDiagnostics()
        guard manifestDiagnostics.isEmpty else {
            throw PhysicalDesignReviewGateError.invalidManifest(manifestDiagnostics.joined(separator: "; "))
        }
        guard manifest.status == .completed,
              let proposedLayout = manifest.proposedLayout,
              let designDiff = manifest.designDiff else {
            throw PhysicalDesignReviewGateError.invalidManifest("completed run does not expose proposed layout and design diff")
        }
        var artifactDigests: [String: String] = [:]
        for artifact in manifest.artifacts {
            let artifactData: Data
            do {
                artifactData = try await artifactStore.read(artifact)
            } catch {
                throw PhysicalDesignReviewGateError.artifactReadFailed(error.localizedDescription)
            }
            guard let expectedDigest = artifact.sha256,
                  !expectedDigest.isEmpty,
                  let expectedByteCount = artifact.byteCount,
                  expectedByteCount >= 0 else {
                throw PhysicalDesignReviewGateError.artifactReadFailed(
                    "\(artifact.path): artifact reference lacks complete integrity metadata"
                )
            }
            let digest = hasher.sha256(data: artifactData)
            if expectedDigest != digest {
                throw PhysicalDesignReviewGateError.artifactReadFailed(
                    "\(artifact.path): SHA-256 digest does not match the manifest reference"
                )
            }
            if Int64(artifactData.count) != expectedByteCount {
                throw PhysicalDesignReviewGateError.artifactReadFailed(
                    "\(artifact.path): byte count does not match the manifest reference"
                )
            }
            artifactDigests[artifact.path] = digest
        }
        guard artifactDigests[proposedLayout.layoutArtifact.path] == proposedLayout.layoutDigest else {
            throw PhysicalDesignReviewGateError.invalidManifest("proposed layout digest does not match its immutable artifact")
        }
        guard artifactDigests[designDiff.path] != nil else {
            throw PhysicalDesignReviewGateError.invalidManifest("design diff is not present in the immutable artifact set")
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
            decisionScope: unique(decisionScope)
        )
        let packetDiagnostics = packet.validationDiagnostics()
        guard packetDiagnostics.isEmpty else {
            throw PhysicalDesignReviewGateError.invalidManifest(packetDiagnostics.joined(separator: "; "))
        }
        return packet
    }

    public func evaluate(
        _ decision: PhysicalDesignReviewDecision,
        for packet: PhysicalDesignReviewPacket
    ) -> PhysicalDesignReviewResult {
        var diagnostics = validate(decision: decision, packet: packet)
        if decision.verdict == .rejected, diagnostics.isEmpty {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .warning,
                code: "physical_design_review_rejected",
                message: "Human review rejected the proposed physical-design revision.",
                suggestedActions: ["repair_the_design", "create_a_new_revision_from_the_last_approved_base"]
            ))
            return PhysicalDesignReviewResult(status: .rejected, diagnostics: diagnostics, packet: packet, decision: decision)
        }
        guard diagnostics.isEmpty else {
            return PhysicalDesignReviewResult(status: .blocked, diagnostics: diagnostics, packet: packet, decision: decision)
        }
        return PhysicalDesignReviewResult(status: .approved, packet: packet, decision: decision)
    }

    public func validateResume(
        _ request: PhysicalDesignResumeRequest,
        packet: PhysicalDesignReviewPacket
    ) -> PhysicalDesignReviewResult {
        var diagnostics = validate(decision: request.decision, packet: packet)
        if request.decision.verdict != .approved {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_resume_approval_missing",
                message: "Resume requires an approved physical-design review decision.",
                suggestedActions: ["obtain_human_approval_before_resume"]
            ))
        }
        if request.runID != packet.runID || request.stage != packet.stage || request.decision.runID != request.runID || request.decision.stage != request.stage {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_resume_scope_mismatch",
                message: "Resume request, decision and review packet do not refer to the same run and stage.",
                suggestedActions: ["reuse_the_original_run_and_stage_identity"]
            ))
        }
        if request.manifestDigest != packet.manifestDigest {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_resume_manifest_stale",
                message: "Resume manifest digest does not match the reviewed immutable manifest.",
                suggestedActions: ["prepare_a_new_review_packet_from_the_current_manifest"]
            ))
        }
        if request.proposedLayoutDigest != packet.proposedLayout.layoutDigest {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_resume_proposed_revision_stale",
                message: "Resume proposed-layout digest does not match the reviewed revision.",
                suggestedActions: ["prepare_a_new_review_packet_for_the_current_revision"]
            ))
        }
        let expectedBaseDigest = packet.baseLayout?.layoutDigest
        if request.expectedBaseLayoutDigest != expectedBaseDigest {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_resume_base_revision_stale",
                message: "Resume base-layout digest does not match the reviewed base revision.",
                suggestedActions: ["resume_from_the_reviewed_base_or_create_a_new_revision"]
            ))
        }
        guard diagnostics.isEmpty else {
            return PhysicalDesignReviewResult(status: .blocked, diagnostics: diagnostics, packet: packet, decision: request.decision)
        }
        return PhysicalDesignReviewResult(status: .readyToResume, packet: packet, decision: request.decision)
    }

    public func validateResumeAgainstCurrentArtifacts(
        _ request: PhysicalDesignResumeRequest,
        packet: PhysicalDesignReviewPacket
    ) async -> PhysicalDesignReviewResult {
        let initial = validateResume(request, packet: packet)
        guard initial.status == .readyToResume else {
            return initial
        }

        do {
            let currentPacket = try await prepareReview(
                manifestReference: packet.manifestReference,
                decisionScope: packet.decisionScope
            )
            guard currentPacket.manifestReference == packet.manifestReference,
                  currentPacket.manifest == packet.manifest,
                  currentPacket.runID == packet.runID,
                  currentPacket.stage == packet.stage,
                  currentPacket.manifestDigest == packet.manifestDigest,
                  currentPacket.proposedLayout == packet.proposedLayout,
                  currentPacket.baseLayout == packet.baseLayout,
                  currentPacket.designDiff == packet.designDiff,
                  currentPacket.artifactDigests == packet.artifactDigests,
                  currentPacket.decisionScope == packet.decisionScope else {
                return PhysicalDesignReviewResult(
                    status: .blocked,
                    diagnostics: [XcircuiteEngineDiagnostic(
                        severity: .error,
                        code: "physical_design_resume_artifacts_stale",
                        message: "Reviewed physical-design artifacts changed after approval and must be reviewed again.",
                        suggestedActions: ["prepare_a_new_review_packet_from_the_current_manifest"]
                    )],
                    packet: packet,
                    decision: request.decision
                )
            }
            return initial
        } catch {
            return PhysicalDesignReviewResult(
                status: .blocked,
                diagnostics: [XcircuiteEngineDiagnostic(
                    severity: .error,
                    code: "physical_design_resume_artifacts_unavailable",
                    message: "Current physical-design artifacts could not be revalidated before resume: \(error.localizedDescription)",
                    suggestedActions: ["restore_review_artifacts", "prepare_a_new_review_packet"]
                )],
                packet: packet,
                decision: request.decision
            )
        }
    }

    private func validate(
        decision: PhysicalDesignReviewDecision,
        packet: PhysicalDesignReviewPacket
    ) -> [XcircuiteEngineDiagnostic] {
        var diagnostics: [XcircuiteEngineDiagnostic] = []
        diagnostics.append(contentsOf: packet.validationDiagnostics().map {
            XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_review_packet_invalid",
                message: $0,
                suggestedActions: ["prepare_a_new_review_packet"]
            )
        })
        if decision.decisionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || decision.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_review_identity_missing",
                message: "Review decision requires a decision ID and reviewer identity.",
                suggestedActions: ["provide_a_reviewer_identity_and_decision_id"]
            ))
        }
        if decision.runID != packet.runID || decision.stage != packet.stage {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_review_scope_mismatch",
                message: "Review decision does not match the packet run and stage.",
                suggestedActions: ["review_the_packet_for_the_same_run_and_stage"]
            ))
        }
        if decision.manifestDigest != packet.manifestDigest {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_review_manifest_stale",
                message: "Review decision references a different manifest digest.",
                suggestedActions: ["prepare_a_new_review_packet"]
            ))
        }
        if decision.proposedLayoutDigest != packet.proposedLayout.layoutDigest {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_review_revision_stale",
                message: "Review decision references a different proposed layout revision.",
                suggestedActions: ["prepare_a_new_review_packet"]
            ))
        }
        if Set(decision.decisionScope) != Set(packet.decisionScope) {
            diagnostics.append(XcircuiteEngineDiagnostic(
                severity: .error,
                code: "physical_design_review_decision_scope_mismatch",
                message: "Review decision scope does not cover the reviewed packet scope.",
                suggestedActions: ["review_all_packet_scope_items_before_deciding"]
            ))
        }
        return diagnostics
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
