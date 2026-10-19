import Foundation
import LogicIR
import LogicDesignSerialization
import PDKCore
import CircuiteFoundation

public struct PhysicalDesignRunManifest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 7

    public var schemaVersion: Int
    public var runID: String
    public var stage: PhysicalDesignStage
    public var status: PhysicalDesignExecutionStatus
    public var design: LogicDesignReference
    public var constraints: PhysicalDesignArtifactBinding
    public var requestedModeIDs: [String]
    public var pdk: PDKReference
    public var processAssets: [String: PhysicalDesignArtifactBinding]
    public var baseLayout: PhysicalDesignReference?
    public var proposedLayout: PhysicalDesignReference?
    public var designDiff: PhysicalDesignArtifactBinding?
    public var artifacts: [PhysicalDesignArtifactBinding]
    public var implementationID: String
    public var implementationVersion: String
    public var deterministicSeed: UInt64?
    public var sourceLayoutFormat: ArtifactFormat?
    public var sourceLayoutDigest: String?
    public var sourceParserID: String?
    public var sourceParserVersion: String?
    public var implementationConfiguration: PhysicalDesignConfiguration?
    public var executionIntent: PhysicalDesignExecutionIntent
    public var placementTimingProfile: PhysicalDesignPlacementTimingReference?
    public var clockTimingModel: PhysicalDesignClockTimingModelReference?
    public var repairMeasurementProfile: PhysicalDesignRepairMeasurementReference?
    public var repairMeasurementEvidence: PhysicalDesignRepairMeasurementEvidence?
    public var sourceAntennaMeasurementEvidence: PhysicalDesignSourceAntennaMeasurementEvidence?
    public var productionConfiguration: PhysicalDesignProductionConfiguration?
    public var processEvidence: PhysicalDesignArtifactBinding?
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
        case processAssets
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
        case placementTimingProfile
        case clockTimingModel
        case repairMeasurementProfile
        case repairMeasurementEvidence
        case sourceAntennaMeasurementEvidence
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
        constraints: PhysicalDesignArtifactBinding,
        requestedModeIDs: [String],
        pdk: PDKReference,
        baseLayout: PhysicalDesignReference?,
        proposedLayout: PhysicalDesignReference?,
        designDiff: PhysicalDesignArtifactBinding?,
        artifacts: [PhysicalDesignArtifactBinding],
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
        placementTimingProfile: PhysicalDesignPlacementTimingReference? = nil,
        productionConfiguration: PhysicalDesignProductionConfiguration? = nil,
        processEvidence: PhysicalDesignArtifactBinding? = nil,
        claims: PhysicalDesignCapabilityClaims,
        processAssets: [String: PhysicalDesignArtifactBinding] = [:],
        repairMeasurementProfile: PhysicalDesignRepairMeasurementReference? = nil,
        repairMeasurementEvidence: PhysicalDesignRepairMeasurementEvidence? = nil,
        sourceAntennaMeasurementEvidence: PhysicalDesignSourceAntennaMeasurementEvidence? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.stage = stage
        self.status = status
        self.design = design
        self.constraints = constraints
        self.requestedModeIDs = requestedModeIDs
        self.pdk = pdk
        self.processAssets = processAssets
        self.repairMeasurementProfile = repairMeasurementProfile
        self.repairMeasurementEvidence = repairMeasurementEvidence
        self.sourceAntennaMeasurementEvidence = sourceAntennaMeasurementEvidence
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
        self.placementTimingProfile = placementTimingProfile
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
        constraints = try container.decode(PhysicalDesignArtifactBinding.self, forKey: .constraints)
        requestedModeIDs = try container.decode([String].self, forKey: .requestedModeIDs)
        pdk = try container.decode(PDKReference.self, forKey: .pdk)
        processAssets = try container.decode([String: PhysicalDesignArtifactBinding].self, forKey: .processAssets)
        baseLayout = try container.decodeIfPresent(PhysicalDesignReference.self, forKey: .baseLayout)
        proposedLayout = try container.decodeIfPresent(PhysicalDesignReference.self, forKey: .proposedLayout)
        designDiff = try container.decodeIfPresent(PhysicalDesignArtifactBinding.self, forKey: .designDiff)
        artifacts = try container.decode([PhysicalDesignArtifactBinding].self, forKey: .artifacts)
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
        placementTimingProfile = try container.decodeIfPresent(PhysicalDesignPlacementTimingReference.self, forKey: .placementTimingProfile)
        repairMeasurementProfile = try container.decodeIfPresent(PhysicalDesignRepairMeasurementReference.self, forKey: .repairMeasurementProfile)
        repairMeasurementEvidence = try container.decodeIfPresent(PhysicalDesignRepairMeasurementEvidence.self, forKey: .repairMeasurementEvidence)
        sourceAntennaMeasurementEvidence = try container.decodeIfPresent(PhysicalDesignSourceAntennaMeasurementEvidence.self, forKey: .sourceAntennaMeasurementEvidence)
        productionConfiguration = try container.decodeIfPresent(PhysicalDesignProductionConfiguration.self, forKey: .productionConfiguration)
        processEvidence = try container.decodeIfPresent(PhysicalDesignArtifactBinding.self, forKey: .processEvidence)
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
        if constraints.descriptor.kind != .constraint || constraints.descriptor.format != .sdc {
            diagnostics.append("constraints are not a canonical SDC artifact")
        }
        diagnostics.append(contentsOf: LogicDesignProvenanceValidation.issues(for: design)
            .filter { $0.code != "design_digest_missing" }
            .map { "design provenance: \($0.message)" })
        if pdk.processID.isEmpty || pdk.version.isEmpty || pdk.digest.isEmpty {
            diagnostics.append("PDK provenance is incomplete")
        }
        if processAssets.keys.contains(where: { $0.isEmpty }) || processAssets.values.contains(where: { $0.descriptor.role != .input || $0.descriptor.format != .lef }) {
            diagnostics.append("process provenance requires nonempty manifest asset IDs and input LEF bindings")
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
        let artifactIDs = artifacts.map(\.logicalID)
        if Set(artifactIDs).count != artifactIDs.count {
            diagnostics.append("artifact IDs are not unique")
        }
        for artifact in artifacts {
            if artifact.reference.digest.algorithm != .sha256
                || artifact.reference.digest.hexadecimalValue.isEmpty {
                diagnostics.append("artifact \(artifact.path) has no SHA-256 digest")
            }
            if artifact.reference.byteCount == 0 && artifact.descriptor.kind != .log {
                diagnostics.append("artifact \(artifact.path) has no valid byte count")
            }
        }
        if let evidence = sourceAntennaMeasurementEvidence {
            if evidence.processManifest != pdk.manifest
                || evidence.processAssets != processAssets.mapValues(\.reference)
                || evidence.candidateSnapshotDigest != proposedLayout?.layoutArtifact.reference.digest
                || claims.production != .blocked {
                diagnostics.append("source antenna measurement candidate/source identity is incomplete")
            }
            switch evidence.coverage {
            case .unassessed:
                if evidence.profile != nil || !evidence.checks.isEmpty || !evidence.targetNetIDs.isEmpty {
                    diagnostics.append("unassessed source antenna coverage cannot carry measured checks")
                }
            case .clean, .violated:
                let candidateChecks = evidence.checks.filter { $0.phase == "candidate" }
                if evidence.profile != repairMeasurementProfile?.artifact.reference
                    || evidence.targetNetIDs.isEmpty || candidateChecks.count != 1
                    || candidateChecks.first?.snapshotDigest != evidence.candidateSnapshotDigest
                    || candidateChecks.first?.input.targetNetIDs != evidence.targetNetIDs
                    || candidateChecks.first?.result.measurements.isEmpty == true
                    || (candidateChecks.first?.result.passed == true) != (evidence.coverage == .clean) {
                    diagnostics.append("source antenna measurement requires exact complete candidate observations")
                }
                for check in evidence.checks {
                    if check.input.targetNetIDs != evidence.targetNetIDs
                        || check.input.rules.isEmpty || check.result.measurements.isEmpty
                        || Set(check.input.terminals.map(\.id)) != Set(check.terminalDeclarations.map(\.pinID))
                        || !Set(check.result.measurements.map(\.ruleID)).isSubset(of: Set(check.input.rules.map(\.id)))
                        || !Set(check.result.measurements.map(\.netID)).isSubset(of: Set(evidence.targetNetIDs))
                        || Set(check.nonConductorRecords.map(\.recordID)).count != check.nonConductorRecords.count
                        || !Set(check.nonConductorRecords.map(\.recordID)).isDisjoint(with: Set(check.input.rectangles.map(\.id)))
                        || !check.nonConductorRecords.allSatisfy({ record in
                            !record.recordID.isEmpty && !record.sourceID.isEmpty && !record.layerID.isEmpty && !record.sourceLayerName.isEmpty
                                && record.minX < record.maxX && record.minY < record.maxY
                                && (record.netID.map { !evidence.targetNetIDs.contains($0) } ?? true)
                        })
                        || !check.result.nonGateComponents.allSatisfy({ witness in
                            check.input.rules.contains { $0.id == witness.ruleID && $0.layerID == witness.stageLayerID }
                                && evidence.targetNetIDs.contains(witness.netID)
                                && Set(witness.componentRecordIDs).isSubset(of: Set(check.input.rectangles.map(\.id)))
                                && Set(witness.terminalIDs).isSubset(of: Set(check.input.terminals.map(\.id)))
                        }) {
                        diagnostics.append("source antenna lower input/result coverage is inconsistent")
                    }
                }
                if stage == .antennaRepair {
                    let before = evidence.checks.filter { $0.phase == "before" }
                    if evidence.coverage != .clean || before.count != 1
                        || before.first?.input.rules != candidateChecks.first?.input.rules
                        || !evidence.targetNetIDs.allSatisfy({ id in
                            before.first?.result.measurements.contains { $0.netID == id && !$0.passed } == true
                        }) {
                        diagnostics.append("source antenna repair requires actual before violations and clean same-source candidate")
                    }
                }
            }
        }
        if let evidence = repairMeasurementEvidence {
            if repairMeasurementProfile?.artifact.reference != evidence.profile
                || proposedLayout?.layoutArtifact.reference.digest != evidence.afterSnapshotDigest
                || evidence.beforeSnapshotDigest.algorithm != .sha256 || evidence.checks.isEmpty
                || !evidence.checks.contains(where: { $0.before.result.diagnostics.contains { $0.severity == .error } }) {
                diagnostics.append("repair measurement exact profile/snapshot identity is incomplete")
            }
            for check in evidence.checks {
                if check.ruleIDs != check.beforeLayout.rules.map(\.id)
                    || check.beforeLayout.rules != check.afterLayout.rules
                    || check.beforeLayout.technologyID != pdk.manifest.id.description
                    || check.beforeLayout.technologyID != check.afterLayout.technologyID
                    || check.beforeLayout.topCell != check.afterLayout.topCell
                    || !check.before.result.completed || !check.after.result.completed || !check.after.result.success
                    || check.after.result.diagnostics.contains(where: { $0.severity == .error }) {
                    diagnostics.append("repair measurement requires complete same-source rule verdicts")
                }
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
