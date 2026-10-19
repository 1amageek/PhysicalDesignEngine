import PEXNative

/// Explicit ideal-source contact faces in the owning snapshot's world DBU frame.
public struct PhysicalDesignClockTopPortElectrode: Sendable, Codable {
    public var pinID: String
    public var faces: [NativePEXElectrodeFace]

    public init(pinID: String, faces: [NativePEXElectrodeFace]) {
        self.pinID = pinID; self.faces = faces
    }
}
