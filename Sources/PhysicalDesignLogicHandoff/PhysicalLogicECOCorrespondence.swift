import CircuiteFoundation

public struct PhysicalLogicECOCorrespondence: Sendable {
    public let instanceIDs: [DesignEntityID: String]
    public let netIDs: [DesignEntityID: String]
    public let portPinIDs: [DesignEntityID: [String]]
    public let stateInstanceIDs: [DesignEntityID: String]

    public init(instanceIDs: [DesignEntityID: String], netIDs: [DesignEntityID: String],
                portPinIDs: [DesignEntityID: [String]], stateInstanceIDs: [DesignEntityID: String]) {
        self.instanceIDs = instanceIDs; self.netIDs = netIDs
        self.portPinIDs = portPinIDs; self.stateInstanceIDs = stateInstanceIDs
    }
}
