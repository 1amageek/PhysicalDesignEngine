import Foundation

public struct PhysicalDesignClockTimingEstimate: Sendable, Hashable, Codable {
    public var cornerID: String
    public var estimatedSkewPS: Double
    public var estimatedLatencyPS: Double
    public var modelDigest: String
    public var pdkManifestDigest: String
    public var rcModelDigest: String
    public var cellLibraryDigest: String

    public init(
        cornerID: String,
        estimatedSkewPS: Double,
        estimatedLatencyPS: Double,
        modelDigest: String,
        pdkManifestDigest: String,
        rcModelDigest: String,
        cellLibraryDigest: String
    ) {
        self.cornerID = cornerID
        self.estimatedSkewPS = estimatedSkewPS
        self.estimatedLatencyPS = estimatedLatencyPS
        self.modelDigest = modelDigest
        self.pdkManifestDigest = pdkManifestDigest
        self.rcModelDigest = rcModelDigest
        self.cellLibraryDigest = cellLibraryDigest
    }
}
