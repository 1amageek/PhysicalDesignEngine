import CircuiteFoundation
import Foundation

public struct PhysicalDesignStageCompletionEvidence: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let runID: String
    public let stage: PhysicalDesignStage
    public let outputLayout: ArtifactReference
    public let metrics: [PhysicalDesignMetric]
    public let completedAt: Date

    public init(
        runID: String,
        stage: PhysicalDesignStage,
        outputLayout: ArtifactReference,
        metrics: [PhysicalDesignMetric],
        completedAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.stage = stage
        self.outputLayout = outputLayout
        self.metrics = metrics.sorted { $0.name < $1.name }
        self.completedAt = completedAt
    }

    public var isValid: Bool {
        let names = metrics.map(\.name)
        return !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && outputLayout.kind == .layout
            && outputLayout.digest.algorithm == .sha256
            && outputLayout.byteCount > 0
            && !metrics.isEmpty
            && names.count == Set(names).count
            && metrics.allSatisfy {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.value.isFinite
            }
            && Set(Self.requiredMetricNames(for: stage)).isSubset(of: Set(names))
            && completedAt.timeIntervalSinceReferenceDate.isFinite
    }

    public static func requiredMetricNames(for stage: PhysicalDesignStage) -> [String] {
        switch stage {
        case .floorplan: ["coreArea"]
        case .powerPlanning: ["powerGridComponentCount"]
        case .placement: ["placedCellCount"]
        case .clockTreeSynthesis: ["clockTreeCount"]
        case .globalRouting: ["routeCount"]
        case .detailedRouting: ["drcViolationCount", "routeCount"]
        case .timingECO: ["holdWorstSlack", "setupWorstSlack"]
        case .drcRepair: ["drcViolationCount"]
        case .antennaRepair: ["antennaViolationCount"]
        case .fillInsertion: ["fillCount", "fillDensity"]
        case .redundantViaInsertion: ["insertedViaCount"]
        case .hotspotRepair: ["hotspotsRepaired", "unresolvedHotspotCount"]
        }
    }
}
