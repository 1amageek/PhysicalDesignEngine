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
        if manifestDigest.isEmpty { diagnostics.append("review packet manifest digest is empty") }
        if proposedLayout.layoutDigest.isEmpty { diagnostics.append("review packet proposed layout digest is empty") }
        if decisionScope.isEmpty { diagnostics.append("review packet decision scope is empty") }
        if Set(decisionScope).count != decisionScope.count { diagnostics.append("review packet decision scope is not unique") }
        return diagnostics
    }

    private static func canonicalTimestamp(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSinceReferenceDate * 1_000).rounded(.down)
        return Date(timeIntervalSinceReferenceDate: milliseconds / 1_000)
    }
}
