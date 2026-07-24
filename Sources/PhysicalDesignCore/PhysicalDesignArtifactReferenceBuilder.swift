import CircuiteFoundation
import Foundation

public struct PhysicalDesignArtifactReferenceBuilder: Sendable {
    private let hasher: SHA256ContentDigester

    public init(hasher: SHA256ContentDigester = SHA256ContentDigester()) {
        self.hasher = hasher
    }

    public func makeReference(
        for write: PhysicalDesignArtifactWrite
    ) throws -> ArtifactReference {
        let location: ArtifactLocation
        do {
            location = try ArtifactLocation(workspaceRelativePath: write.relativePath)
        } catch {
            throw PhysicalDesignStoreError.invalidPath(write.relativePath)
        }
        let digest = try hasher.digest(data: write.data, using: .sha256)
        let locator = ArtifactLocator(
            location: location,
            role: .output,
            kind: write.kind,
            format: write.format
        )
        return ArtifactReference(
            id: ArtifactID(stableKey: [
                "physical-design",
                write.runID,
                write.relativePath,
                write.kind.rawValue,
                write.format.rawValue,
                digest.hexadecimalValue,
            ].joined(separator: ":")),
            locator: locator,
            digest: digest,
            byteCount: UInt64(write.data.count)
        )
    }
}
