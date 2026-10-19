public struct PhysicalDesignPlacementTimingReference: Sendable, Hashable, Codable {
    public let artifact: PhysicalDesignArtifactBinding
    public let maximumInputBytes: UInt64
    public let maximumLiveBytes: UInt64
    public let maximumWorkUnits: UInt64
    public let maximumPathWorkUnitsPerAnalysis: UInt64
    public let maximumPathStates: Int
    public let maximumEvidenceBytes: UInt64
    public let timeoutNanoseconds: UInt64
    public init(artifact: PhysicalDesignArtifactBinding, maximumInputBytes: UInt64, maximumLiveBytes: UInt64,
                maximumWorkUnits: UInt64, maximumPathWorkUnitsPerAnalysis: UInt64, maximumPathStates: Int,
                maximumEvidenceBytes: UInt64, timeoutNanoseconds: UInt64) {
        self.artifact = artifact; self.maximumInputBytes = maximumInputBytes; self.maximumLiveBytes = maximumLiveBytes
        self.maximumWorkUnits = maximumWorkUnits; self.maximumPathWorkUnitsPerAnalysis = maximumPathWorkUnitsPerAnalysis
        self.maximumPathStates = maximumPathStates; self.maximumEvidenceBytes = maximumEvidenceBytes; self.timeoutNanoseconds = timeoutNanoseconds
    }
}
