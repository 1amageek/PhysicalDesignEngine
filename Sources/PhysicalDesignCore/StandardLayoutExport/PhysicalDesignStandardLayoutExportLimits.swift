public struct PhysicalDesignStandardLayoutExportLimits: Sendable, Hashable {
    public let maximumInputByteCount: UInt64
    public let maximumGeometryRecordCount: UInt64
    public let maximumOutputByteCount: UInt64

    public init(maximumInputByteCount: UInt64, maximumGeometryRecordCount: UInt64, maximumOutputByteCount: UInt64) {
        self.maximumInputByteCount = maximumInputByteCount
        self.maximumGeometryRecordCount = maximumGeometryRecordCount
        self.maximumOutputByteCount = maximumOutputByteCount
    }
}
