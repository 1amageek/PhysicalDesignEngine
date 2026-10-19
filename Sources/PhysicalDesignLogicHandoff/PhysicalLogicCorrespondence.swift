import CircuiteFoundation

public struct PhysicalLogicCorrespondence: Sendable {
    public let instanceIDs: [DesignEntityID: String]
    public let portPinIDs: [DesignEntityID: [String]]
    public init(instanceIDs: [DesignEntityID: String], portPinIDs: [DesignEntityID: [String]]) {
        self.instanceIDs = instanceIDs; self.portPinIDs = portPinIDs
    }
}
