import Foundation

public enum PhysicalDesignAntennaRepairStrategy: String, Sendable, Hashable, Codable, CaseIterable {
    case jumper
    case reroute
    case protectionDevice = "protection_device"
}
