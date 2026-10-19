import Foundation

public struct PhysicalDesignRepairMeasurementLimits: Sendable, Hashable, Codable {
    public let maximumInputBytes: Int
    public let maximumProjectionRecords: Int
    public let maximumGeometryProbes: Int
    public let maximumBackendWork: Int
    public let timeoutSeconds: Double
    public init(maximumInputBytes: Int, maximumProjectionRecords: Int, maximumGeometryProbes: Int,
                maximumBackendWork: Int, timeoutSeconds: Double) {
        self.maximumInputBytes = maximumInputBytes; self.maximumProjectionRecords = maximumProjectionRecords
        self.maximumGeometryProbes = maximumGeometryProbes; self.maximumBackendWork = maximumBackendWork
        self.timeoutSeconds = timeoutSeconds
    }
}
