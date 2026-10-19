import Foundation

public struct PhysicalDesignAntennaProtection: Sendable, Hashable, Codable {
    public let master: String
    public let diffusionPin: String
    public let otherPinNetIDs: [String: String]
    public init(master: String, diffusionPin: String, otherPinNetIDs: [String: String]) {
        self.master = master; self.diffusionPin = diffusionPin; self.otherPinNetIDs = otherPinNetIDs
    }
}
