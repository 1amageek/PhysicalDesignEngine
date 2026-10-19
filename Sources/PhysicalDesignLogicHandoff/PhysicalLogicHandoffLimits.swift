public struct PhysicalLogicHandoffLimits: Sendable {
    public let maximumInstances: Int
    public let maximumPins: Int
    public let maximumNets: Int
    public init(maximumInstances: Int, maximumPins: Int, maximumNets: Int) throws(PhysicalLogicHandoffError) {
        guard maximumInstances > 0, maximumPins > 0, maximumNets > 0 else { throw .invalidMapping("Limits must be positive") }
        self.maximumInstances = maximumInstances; self.maximumPins = maximumPins; self.maximumNets = maximumNets
    }
}
