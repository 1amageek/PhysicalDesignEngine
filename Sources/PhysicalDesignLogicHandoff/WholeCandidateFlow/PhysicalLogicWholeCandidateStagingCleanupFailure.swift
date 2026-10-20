import Foundation

/// An inspectable failed cleanup of this producer's exclusive staging directory.
public struct PhysicalLogicWholeCandidateStagingCleanupFailure: Error, Sendable {
    public let primary: PhysicalLogicWholeCandidateFlowFailure?
    public let secondary: any Error
    public let directory: URL
    private let owner: PhysicalLogicWholeCandidateStaging

    /// Exact refusal reasons from the directory capability boundary.
    public enum DirectoryFailure: Error, Sendable {
        public enum Operation: Sendable { case create, inspect }
        case systemCall(operation: Operation, code: Int32)
        case missing
        case replacement
        case unverifiedIdentity
        case duplicateWrite
        case unrepresentablePath
    }

    internal init(primary: PhysicalLogicWholeCandidateFlowFailure?, secondary: any Error,
        owner: PhysicalLogicWholeCandidateStaging) {
        self.primary = primary; self.secondary = secondary
        self.directory = owner.directory; self.owner = owner
    }

    /// Cleanup runs despite cancellation; copied failures share this one idempotent owner.
    public func retry() async throws { try await owner.remove() }
}
