import TimingCore

/// Retained source classification; these records grant neither timing eligibility nor supply measurement.
public struct PhysicalDesignPlacementSourceBindings: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable { case signal, power, ground }
    public enum Coverage: String, Sendable, Hashable, Codable { case boundSignal, boundSupply, sourceOnlySupply }

    public struct TerminalBinding: Sendable, Hashable, Codable {
        public let physicalPinID: String?
        public let instanceID: String?
        public let masterName: String?
        public let pinName: String
        public let netID: String?
        public let lefAssetID: String?
        public let role: Role
        public let coverage: Coverage
        public let direction: String
        public let libertyCellOffset: Int?
        public let libertyPinOffset: Int?

        public init(physicalPinID: String?, instanceID: String?, masterName: String?, pinName: String,
                    netID: String?, lefAssetID: String?, role: Role, coverage: Coverage, direction: String,
                    libertyCellOffset: Int?, libertyPinOffset: Int?) {
            self.physicalPinID = physicalPinID; self.instanceID = instanceID; self.masterName = masterName
            self.pinName = pinName; self.netID = netID; self.lefAssetID = lefAssetID
            self.role = role; self.coverage = coverage; self.direction = direction
            self.libertyCellOffset = libertyCellOffset; self.libertyPinOffset = libertyPinOffset
        }
    }

    public struct ConstantBinding: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable { case logicalLiteral, sourceTieOutput }
        public let netID: String
        public let value: TimingDesign.Constant
        public let kind: Kind
        public let driverInstance: String?
        public let driverPin: String?

        public init(netID: String, value: TimingDesign.Constant, kind: Kind, driverInstance: String?, driverPin: String?) {
            self.netID = netID; self.value = value; self.kind = kind
            self.driverInstance = driverInstance; self.driverPin = driverPin
        }
    }

    public struct SequentialBinding: Sendable, Hashable, Codable {
        public let instanceID: String
        public let masterName: String
        public let sourceCellOffset: Int
        public let sourceSequentialOffsets: [Int]

        public init(instanceID: String, masterName: String, sourceCellOffset: Int, sourceSequentialOffsets: [Int]) {
            self.instanceID = instanceID; self.masterName = masterName
            self.sourceCellOffset = sourceCellOffset; self.sourceSequentialOffsets = sourceSequentialOffsets
        }
    }

    public let schemaVersion: Int
    public let terminals: [TerminalBinding]
    public let constants: [ConstantBinding]
    public let sequentialBindings: [SequentialBinding]

    public init(terminals: [TerminalBinding], constants: [ConstantBinding], sequentialBindings: [SequentialBinding]) {
        schemaVersion = 1; self.terminals = terminals; self.constants = constants
        self.sequentialBindings = sequentialBindings
    }
}
