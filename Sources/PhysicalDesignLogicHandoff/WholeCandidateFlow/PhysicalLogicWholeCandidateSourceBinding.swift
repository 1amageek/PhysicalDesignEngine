/// Proposed correspondence, checked against every actual canonical Timing source.
public struct PhysicalLogicWholeCandidateSourceBinding: Sendable {
    public let sourceIndex: Int
    public let physicalPinID: String
    public let sourceDeviceName: String?
    public init(sourceIndex: Int, physicalPinID: String, sourceDeviceName: String?) {
        self.sourceIndex = sourceIndex; self.physicalPinID = physicalPinID; self.sourceDeviceName = sourceDeviceName
    }
}
