public enum PhysicalDesignStandardLayoutExportError: Error, Sendable, Equatable {
    public enum Resource: Sendable, Equatable { case inputBytes, geometryRecords, outputBytes }
    case sourceIdentityMismatch(String)
    case limitExceeded(Resource)
    case invalidSource(String)
    case invalidSnapshot(String)
    case artifactReadFailed(String)
    case encodingFailed(String)
    case cancelled
}
