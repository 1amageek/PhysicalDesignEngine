import Foundation
import LogicIR
import PDKCore
import TimingCore
import XcircuitePackage

public struct PhysicalDesignRunManifest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var stage: PhysicalDesignStage
    public var status: XcircuiteEngineExecutionStatus
    public var design: LogicDesignReference
    public var constraints: TimingConstraintReference
    public var pdk: PDKReference
    public var baseLayout: PhysicalDesignReference?
    public var proposedLayout: PhysicalDesignReference?
    public var designDiff: XcircuiteFileReference?
    public var artifacts: [XcircuiteFileReference]
    public var implementationID: String
    public var implementationVersion: String
    public var deterministicSeed: UInt64?
    public var createdAt: Date
    public var completedAt: Date

    public init(
        runID: String,
        stage: PhysicalDesignStage,
        status: XcircuiteEngineExecutionStatus,
        design: LogicDesignReference,
        constraints: TimingConstraintReference,
        pdk: PDKReference,
        baseLayout: PhysicalDesignReference?,
        proposedLayout: PhysicalDesignReference?,
        designDiff: XcircuiteFileReference?,
        artifacts: [XcircuiteFileReference],
        implementationID: String,
        implementationVersion: String,
        deterministicSeed: UInt64?,
        createdAt: Date,
        completedAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.stage = stage
        self.status = status
        self.design = design
        self.constraints = constraints
        self.pdk = pdk
        self.baseLayout = baseLayout
        self.proposedLayout = proposedLayout
        self.designDiff = designDiff
        self.artifacts = artifacts
        self.implementationID = implementationID
        self.implementationVersion = implementationVersion
        self.deterministicSeed = deterministicSeed
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            diagnostics.append("unsupported run manifest schema version")
        }
        if runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append("run ID is empty")
        }
        if design.designDigest.isEmpty {
            diagnostics.append("design digest is empty")
        }
        if pdk.processID.isEmpty || pdk.version.isEmpty || pdk.digest.isEmpty {
            diagnostics.append("PDK provenance is incomplete")
        }
        if implementationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || implementationVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append("implementation provenance is incomplete")
        }
        if completedAt < createdAt {
            diagnostics.append("completed timestamp precedes created timestamp")
        }
        if status == .completed && proposedLayout == nil {
            diagnostics.append("completed manifest has no proposed layout")
        }
        if status == .completed && designDiff == nil {
            diagnostics.append("completed manifest has no design diff")
        }
        let artifactPaths = Set(artifacts.map(\.path))
        if artifactPaths.count != artifacts.count {
            diagnostics.append("artifact paths are not unique")
        }
        if let proposedLayout, !artifactPaths.contains(proposedLayout.layoutArtifact.path) {
            diagnostics.append("proposed layout is not present in the artifact set")
        }
        if let designDiff, !artifactPaths.contains(designDiff.path) {
            diagnostics.append("design diff is not present in the artifact set")
        }
        let artifactIDs = artifacts.compactMap(\.artifactID)
        if Set(artifactIDs).count != artifactIDs.count {
            diagnostics.append("artifact IDs are not unique")
        }
        for artifact in artifacts where artifact.producedByRunID != runID {
            diagnostics.append("artifact \(artifact.path) is not produced by run \(runID)")
        }
        return diagnostics
    }
}
