public enum PhysicalDesignDEFExportError: Error, Sendable, Equatable {
    case unresolvedProcessSources
    case unsupportedProcessGeometry(String)
    case invalidSnapshot(String)
}
