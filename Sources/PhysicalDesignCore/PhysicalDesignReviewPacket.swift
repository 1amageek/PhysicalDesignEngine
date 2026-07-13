import Foundation
import XcircuitePackage

public struct PhysicalDesignReviewPacket: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var stage: PhysicalDesignStage
    public var manifest: PhysicalDesignRunManifest
    public var manifestReference: XcircuiteFileReference
    public var manifestDigest: String
    public var baseLayout: PhysicalDesignReference?
    public var proposedLayout: PhysicalDesignReference
    public var designDiff: XcircuiteFileReference
    public var artifactDigests: [String: String]
    public var decisionScope: [String]
    public var createdAt: Date

    public init(
        runID: String,
        stage: PhysicalDesignStage,
        manifest: PhysicalDesignRunManifest,
        manifestReference: XcircuiteFileReference,
        manifestDigest: String,
        baseLayout: PhysicalDesignReference?,
        proposedLayout: PhysicalDesignReference,
        designDiff: XcircuiteFileReference,
        artifactDigests: [String: String],
        decisionScope: [String],
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.stage = stage
        self.manifest = manifest
        self.manifestReference = manifestReference
        self.manifestDigest = manifestDigest
        self.baseLayout = baseLayout
        self.proposedLayout = proposedLayout
        self.designDiff = designDiff
        self.artifactDigests = artifactDigests
        self.decisionScope = decisionScope
        self.createdAt = Self.canonicalTimestamp(createdAt)
    }

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if schemaVersion != Self.currentSchemaVersion { diagnostics.append("unsupported review packet schema version") }
        if runID.isEmpty || manifest.runID != runID { diagnostics.append("review packet run ID does not match the manifest") }
        if manifest.stage != stage { diagnostics.append("review packet stage does not match the manifest") }
        diagnostics.append(contentsOf: proposedLayout.validationDiagnostics().map { "proposed layout: \($0)" })
        if let baseLayout {
            diagnostics.append(contentsOf: baseLayout.validationDiagnostics().map { "base layout: \($0)" })
        }
        if manifestDigest.isEmpty { diagnostics.append("review packet manifest digest is empty") }
        if proposedLayout.layoutDigest.isEmpty { diagnostics.append("review packet proposed layout digest is empty") }
        if decisionScope.isEmpty { diagnostics.append("review packet decision scope is empty") }
        if Set(decisionScope).count != decisionScope.count { diagnostics.append("review packet decision scope is not unique") }
        if manifestReference.sha256?.isEmpty != false || manifestReference.byteCount == nil || manifestReference.byteCount ?? -1 < 0 {
            diagnostics.append("review packet manifest reference lacks complete integrity metadata")
        }
        let manifestArtifactPaths = Set(manifest.artifacts.map(\.path))
        if Set(artifactDigests.keys) != manifestArtifactPaths {
            diagnostics.append("review packet digest map does not exactly match the manifest artifact set")
        }
        for artifact in manifest.artifacts {
            guard let digest = artifactDigests[artifact.path], !digest.isEmpty else {
                diagnostics.append("review packet is missing the verified digest for \(artifact.path)")
                continue
            }
            if let expectedDigest = artifact.sha256, expectedDigest != digest {
                diagnostics.append("review packet digest does not match the manifest reference for \(artifact.path)")
            }
            if artifact.byteCount == nil || artifact.byteCount ?? -1 < 0 {
                diagnostics.append("review packet artifact lacks complete integrity metadata for \(artifact.path)")
            }
        }
        if artifactDigests[proposedLayout.layoutArtifact.path] != proposedLayout.layoutDigest {
            diagnostics.append("review packet proposed layout is not bound to its verified artifact digest")
        }
        if artifactDigests[designDiff.path] == nil {
            diagnostics.append("review packet design diff is not bound to a verified artifact")
        }
        return diagnostics
    }

    private static func canonicalTimestamp(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSinceReferenceDate * 1_000).rounded(.down)
        return Date(timeIntervalSinceReferenceDate: milliseconds / 1_000)
    }
}
