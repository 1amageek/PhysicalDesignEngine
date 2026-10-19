import CircuiteFoundation
import STAEngine

public struct PhysicalDesignPlacementTimingProfile: Sendable, Hashable, Codable {
    public enum ClockPolicy: String, Sendable, Hashable, Codable {
        case sourcePropagatedPrimary
    }
    public enum CheckPolicy: String, Sendable, Hashable, Codable {
        case completeSourceApplicable
    }
    public let schemaVersion: Int
    public let model: String
    public let manifest: ArtifactReference
    public let library: PhysicalDesignArtifactBinding
    public let libertyAssetID: String
    public let capacitanceAssetID: String
    public let cornerID: String
    public let rcCornerID: String
    public let conditionName: String
    public let wireLayer: Int
    public let wireWidthDBU: Int64
    public let minimumSetupSlackSeconds: Double?
    public let clockPolicy: ClockPolicy?
    public let checkPolicy: CheckPolicy?
    public let operatingSupplyAssumptions: [STAOperatingSupplyAssumption]?
    public let distributedRC: STADistributedRCOptions?
    public init(manifest: ArtifactReference, library: PhysicalDesignArtifactBinding, libertyAssetID: String,
                capacitanceAssetID: String, cornerID: String, rcCornerID: String, conditionName: String,
                wireLayer: Int, wireWidthDBU: Int64, minimumSetupSlackSeconds: Double? = nil) {
        self.init(schemaVersion: 1, model: "lefGroundCapacitanceStarV1", manifest: manifest,
            library: library, libertyAssetID: libertyAssetID, capacitanceAssetID: capacitanceAssetID,
            cornerID: cornerID, rcCornerID: rcCornerID, conditionName: conditionName,
            wireLayer: wireLayer, wireWidthDBU: wireWidthDBU, minimumSetupSlackSeconds: minimumSetupSlackSeconds,
            clockPolicy: nil, checkPolicy: nil, operatingSupplyAssumptions: nil, distributedRC: nil)
    }

    public static func sourceBoundSequential(manifest: ArtifactReference, library: PhysicalDesignArtifactBinding,
                libertyAssetID: String, capacitanceAssetID: String, cornerID: String, rcCornerID: String,
                conditionName: String, wireLayer: Int, wireWidthDBU: Int64,
                operatingSupplyAssumptions: [STAOperatingSupplyAssumption],
                distributedRC: STADistributedRCOptions,
                minimumSetupSlackSeconds: Double? = nil) -> Self {
        .init(schemaVersion: 2, model: "lefDistributedRCStarV2", manifest: manifest,
            library: library, libertyAssetID: libertyAssetID, capacitanceAssetID: capacitanceAssetID,
            cornerID: cornerID, rcCornerID: rcCornerID, conditionName: conditionName,
            wireLayer: wireLayer, wireWidthDBU: wireWidthDBU, minimumSetupSlackSeconds: minimumSetupSlackSeconds,
            clockPolicy: .sourcePropagatedPrimary, checkPolicy: .completeSourceApplicable,
            operatingSupplyAssumptions: operatingSupplyAssumptions, distributedRC: distributedRC)
    }

    var isSourceBoundSequential: Bool {
        schemaVersion == 2 && model == "lefDistributedRCStarV2"
            && clockPolicy == .sourcePropagatedPrimary && checkPolicy == .completeSourceApplicable
            && operatingSupplyAssumptions != nil && distributedRC != nil
    }

    private init(schemaVersion: Int, model: String, manifest: ArtifactReference,
                 library: PhysicalDesignArtifactBinding, libertyAssetID: String, capacitanceAssetID: String,
                 cornerID: String, rcCornerID: String, conditionName: String, wireLayer: Int,
                 wireWidthDBU: Int64, minimumSetupSlackSeconds: Double?, clockPolicy: ClockPolicy?, checkPolicy: CheckPolicy?,
                 operatingSupplyAssumptions: [STAOperatingSupplyAssumption]?, distributedRC: STADistributedRCOptions?) {
        self.schemaVersion = schemaVersion; self.model = model; self.manifest = manifest; self.library = library
        self.libertyAssetID = libertyAssetID; self.capacitanceAssetID = capacitanceAssetID
        self.cornerID = cornerID; self.rcCornerID = rcCornerID; self.conditionName = conditionName
        self.wireLayer = wireLayer; self.wireWidthDBU = wireWidthDBU; self.minimumSetupSlackSeconds = minimumSetupSlackSeconds
        self.clockPolicy = clockPolicy; self.checkPolicy = checkPolicy
        self.operatingSupplyAssumptions = operatingSupplyAssumptions
        self.distributedRC = distributedRC
    }
}
