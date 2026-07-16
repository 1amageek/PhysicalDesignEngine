import CircuiteFoundation
import Foundation

public struct PhysicalDesignCapability: Sendable, Hashable, Codable {
    public let engineID: String
    public let contractVersion: Int
    public let supportedInputFormats: [ArtifactFormat]
    public let supportedOutputFormats: [ArtifactFormat]
    public let features: [String]
    public let limitations: [String]
    public let supportedExecutionIntents: [PhysicalDesignExecutionIntent]

    public init(
        engineID: String,
        contractVersion: Int,
        supportedInputFormats: [ArtifactFormat],
        supportedOutputFormats: [ArtifactFormat],
        features: [String],
        limitations: [String],
        supportedExecutionIntents: [PhysicalDesignExecutionIntent]
    ) {
        self.engineID = engineID
        self.contractVersion = contractVersion
        self.supportedInputFormats = supportedInputFormats
        self.supportedOutputFormats = supportedOutputFormats
        self.features = features
        self.limitations = limitations
        self.supportedExecutionIntents = supportedExecutionIntents
    }
}
