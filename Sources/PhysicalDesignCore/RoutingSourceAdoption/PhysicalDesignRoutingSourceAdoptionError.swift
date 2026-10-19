public struct PhysicalDesignRoutingSourceAdoptionError: Error, Sendable {
    public enum Reason: String, Sendable {
        case parentMismatch, sourceMismatch, changedFacts, unsupported, layerCollision, limitsExceeded, sourceValidation
    }
    public let reason: Reason
    public let message: String
    public let underlyingCause: (any Error)?

    init(_ reason: Reason, _ message: String, cause: (any Error)? = nil) {
        self.reason = reason; self.message = message; underlyingCause = cause
    }
}
