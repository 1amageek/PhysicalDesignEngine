import CircuiteFoundation
import DRCNative
import Foundation

public struct PhysicalDesignRepairMeasurementProfile: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let processManifest: ArtifactReference
    public let processAssets: [String: ArtifactReference]
    public let processLayerOrder: [String]
    public let rules: [NativeDRCRule]
    public let antennaNetIDs: [String]
    public let hotspots: [PhysicalDesignHotspotConstraint]
    public let protection: PhysicalDesignAntennaProtection?
    public let antennaLimitPolicy: PhysicalDesignAntennaLimitPolicy
    public let requireNumericalAntennaRatio: Bool

    public init(processManifest: ArtifactReference, processAssets: [String: ArtifactReference],
                processLayerOrder: [String], rules: [NativeDRCRule], antennaNetIDs: [String] = [],
                hotspots: [PhysicalDesignHotspotConstraint] = [], protection: PhysicalDesignAntennaProtection? = nil,
                requireNumericalAntennaRatio: Bool = false, antennaLimitPolicy: PhysicalDesignAntennaLimitPolicy = .legacyScalarLimit) {
        self.antennaLimitPolicy = antennaLimitPolicy
        schemaVersion = antennaLimitPolicy == .sourceProcessLaws ? 2 : 1; self.processManifest = processManifest; self.processAssets = processAssets
        self.processLayerOrder = processLayerOrder; self.rules = rules; self.antennaNetIDs = antennaNetIDs
        self.hotspots = hotspots; self.protection = protection; self.requireNumericalAntennaRatio = requireNumericalAntennaRatio
    }
}
