import Foundation
import LogicIR
import PDKCore
import CircuiteFoundation

public struct PhysicalDesignRunManifest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var runID: String
    public var stage: PhysicalDesignStage
    public var status: PhysicalDesignExecutionStatus
    public var design: LogicDesignReference
    public var constraints: ArtifactReference
    public var requestedModeIDs: [String]
    public var pdk: PDKReference
    public var baseLayout: PhysicalDesignReference?
    public var proposedLayout: PhysicalDesignReference?
    public var designDiff: ArtifactReference?
    public var artifacts: [ArtifactReference]
    public var implementationID: String
    public var implementationVersion: String
    public var deterministicSeed: UInt64?
    public var sourceLayoutFormat: ArtifactFormat?
    public var sourceLayoutDigest: String?
    public var sourceParserID: String?
    public var sourceParserVersion: String?
    public var implementationConfiguration: PhysicalDesignConfiguration?
    public var executionIntent: PhysicalDesignExecutionIntent
    public var clockTimingModel: PhysicalDesignClockTimingModelReference?
    public var productionConfiguration: PhysicalDesignProductionConfiguration?
    public var processEvidence: ArtifactReference?
    public var claims: PhysicalDesignCapabilityClaims
    public var createdAt: Date
    public var completedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case stage
        case status
        case design
        case constraints
        case requestedModeIDs
        case pdk
        case baseLayout
        case proposedLayout
        case designDiff
        case artifacts
        case implementationID
        case implementationVersion
        case deterministicSeed
        case sourceLayoutFormat
        case sourceLayoutDigest
        case sourceParserID
        case sourceParserVersion
        case implementationConfiguration
        case executionIntent
        case clockTimingModel
        case productionConfiguration
        case processEvidence
        case claims
        case createdAt
        case completedAt
    }

    public init(
        runID: String,
        stage: PhysicalDesignStage,
        status: PhysicalDesignExecutionStatus,
        design: LogicDesignReference,
        constraints: ArtifactReference,
        requestedModeIDs: [String],
        pdk: PDKReference,
        baseLayout: PhysicalDesignReference?,
        proposedLayout: PhysicalDesignReference?,
        designDiff: ArtifactReference?,
        artifacts: [ArtifactReference],
        implementationID: String,
        implementationVersion: String,
        deterministicSeed: UInt64?,
        createdAt: Date,
        completedAt: Date,
        sourceLayoutFormat: ArtifactFormat? = nil,
        sourceLayoutDigest: String? = nil,
        sourceParserID: String? = nil,
        sourceParserVersion: String? = nil,
        implementationConfiguration: PhysicalDesignConfiguration? = nil,
        executionIntent: PhysicalDesignExecutionIntent,
        clockTimingModel: PhysicalDesignClockTimingModelReference? = nil,
        productionConfiguration: PhysicalDesignProductionConfiguration? = nil,
        processEvidence: ArtifactReference? = nil,
        claims: PhysicalDesignCapabilityClaims
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.stage = stage
        self.status = status
        self.design = design
        self.constraints = constraints
        self.requestedModeIDs = requestedModeIDs
        self.pdk = pdk
        self.baseLayout = baseLayout
        self.proposedLayout = proposedLayout
        self.designDiff = designDiff
        self.artifacts = artifacts
        self.implementationID = implementationID
        self.implementationVersion = implementationVersion
        self.deterministicSeed = deterministicSeed
        self.sourceLayoutFormat = sourceLayoutFormat
        self.sourceLayoutDigest = sourceLayoutDigest
        self.sourceParserID = sourceParserID
        self.sourceParserVersion = sourceParserVersion
        self.implementationConfiguration = implementationConfiguration
        self.executionIntent = executionIntent
        self.clockTimingModel = clockTimingModel
        self.productionConfiguration = productionConfiguration
        self.processEvidence = processEvidence
        self.claims = claims
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported physical design run manifest schema version \(schemaVersion)."
            )
        }
        runID = try container.decode(String.self, forKey: .runID)
        stage = try container.decode(PhysicalDesignStage.self, forKey: .stage)
        status = try container.decode(PhysicalDesignExecutionStatus.self, forKey: .status)
        design = try container.decode(LogicDesignReference.self, forKey: .design)
        constraints = try container.decode(ArtifactReference.self, forKey: .constraints)
        requestedModeIDs = try container.decode([String].self, forKey: .requestedModeIDs)
        pdk = try container.decode(PDKReference.self, forKey: .pdk)
        baseLayout = try container.decodeIfPresent(PhysicalDesignReference.self, forKey: .baseLayout)
        proposedLayout = try container.decodeIfPresent(PhysicalDesignReference.self, forKey: .proposedLayout)
        designDiff = try container.decodeIfPresent(ArtifactReference.self, forKey: .designDiff)
        artifacts = try container.decode([ArtifactReference].self, forKey: .artifacts)
        implementationID = try container.decode(String.self, forKey: .implementationID)
        implementationVersion = try container.decode(String.self, forKey: .implementationVersion)
        deterministicSeed = try container.decodeIfPresent(UInt64.self, forKey: .deterministicSeed)
        sourceLayoutFormat = try container.decodeIfPresent(ArtifactFormat.self, forKey: .sourceLayoutFormat)
        sourceLayoutDigest = try container.decodeIfPresent(String.self, forKey: .sourceLayoutDigest)
        sourceParserID = try container.decodeIfPresent(String.self, forKey: .sourceParserID)
        sourceParserVersion = try container.decodeIfPresent(String.self, forKey: .sourceParserVersion)
        implementationConfiguration = try container.decodeIfPresent(PhysicalDesignConfiguration.self, forKey: .implementationConfiguration)
        executionIntent = try container.decode(PhysicalDesignExecutionIntent.self, forKey: .executionIntent)
        clockTimingModel = try container.decodeIfPresent(PhysicalDesignClockTimingModelReference.self, forKey: .clockTimingModel)
        productionConfiguration = try container.decodeIfPresent(PhysicalDesignProductionConfiguration.self, forKey: .productionConfiguration)
        processEvidence = try container.decodeIfPresent(ArtifactReference.self, forKey: .processEvidence)
        claims = try container.decode(PhysicalDesignCapabilityClaims.self, forKey: .claims)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
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
        if requestedModeIDs.isEmpty {
            diagnostics.append("requested timing mode IDs are empty")
        }
        let normalizedModeIDs = requestedModeIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalizedModeIDs.contains(where: \.isEmpty) {
            diagnostics.append("requested timing mode IDs contain a blank identifier")
        }
        if Set(normalizedModeIDs).count != normalizedModeIDs.count {
            diagnostics.append("requested timing mode IDs are not unique")
        }
        if constraints.kind != .constraint || constraints.format != .sdc {
            diagnostics.append("constraints are not a canonical SDC artifact")
        }
        diagnostics.append(contentsOf: LogicDesignProvenanceValidation.issues(for: design)
            .filter { $0.code != "design_digest_missing" }
            .map { "design provenance: \($0.message)" })
        if pdk.processID.isEmpty || pdk.version.isEmpty || pdk.digest.isEmpty {
            diagnostics.append("PDK provenance is incomplete")
        }
        let sourceFields = [sourceLayoutDigest, sourceParserID, sourceParserVersion]
        if sourceLayoutFormat == nil && sourceFields.contains(where: { $0 != nil }) {
            diagnostics.append("source layout provenance is incomplete")
        }
        if sourceLayoutFormat != nil {
            if sourceLayoutDigest?.isEmpty != false {
                diagnostics.append("source layout digest is empty")
            }
            if sourceParserID?.isEmpty != false || sourceParserVersion?.isEmpty != false {
                diagnostics.append("source parser provenance is incomplete")
            }
        }
        if let implementationConfiguration {
            diagnostics.append(contentsOf: implementationConfiguration.validationDiagnostics().map { "implementation configuration: \($0)" })
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
        if status == .completed && claims.geometry != .verified {
            diagnostics.append("completed manifest must retain a verified geometry claim")
        }
        if claims.timing == .verified && clockTimingModel == nil {
            diagnostics.append("verified timing claim requires a retained clock timing model")
        }
        if status == .completed && artifacts.count < 3 {
            diagnostics.append("completed manifest must contain at least the JSON revision, DEF revision and design diff artifacts")
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
        if executionIntent == .productionImplementation {
            if productionConfiguration == nil {
                diagnostics.append("production implementation has no retained production configuration")
            }
            if processEvidence == nil {
                diagnostics.append("production implementation has no retained process evidence")
            }
        }
        if let processEvidence, !artifactPaths.contains(processEvidence.path) {
            diagnostics.append("process evidence is not present in the artifact set")
        }
        let artifactIDs = artifacts.map(\.artifactID)
        if Set(artifactIDs).count != artifactIDs.count {
            diagnostics.append("artifact IDs are not unique")
        }
        for artifact in artifacts {
            if artifact.path.hasPrefix("/") {
                diagnostics.append("artifact \(artifact.path) is not project-relative")
            }
            if artifact.digest.algorithm != .sha256
                || artifact.digest.hexadecimalValue.isEmpty {
                diagnostics.append("artifact \(artifact.path) has no SHA-256 digest")
            }
            if artifact.byteCount == 0 && artifact.kind != .log {
                diagnostics.append("artifact \(artifact.path) has no valid byte count")
            }
        }
        if let proposedLayout {
            diagnostics.append(contentsOf: proposedLayout.validationDiagnostics().map { "proposed layout: \($0)" })
        }
        if let baseLayout {
            diagnostics.append(contentsOf: baseLayout.validationDiagnostics().map { "base layout: \($0)" })
        }
        return diagnostics
    }
}
