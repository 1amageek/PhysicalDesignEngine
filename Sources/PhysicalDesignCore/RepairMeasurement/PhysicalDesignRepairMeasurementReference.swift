import Foundation

public struct PhysicalDesignRepairMeasurementReference: Sendable, Hashable, Codable {
    public let artifact: PhysicalDesignArtifactBinding
    public let limits: PhysicalDesignRepairMeasurementLimits
    public init(artifact: PhysicalDesignArtifactBinding, limits: PhysicalDesignRepairMeasurementLimits) {
        self.artifact = artifact; self.limits = limits
    }
}
