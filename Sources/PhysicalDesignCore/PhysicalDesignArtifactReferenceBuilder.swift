import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation

public struct PhysicalDesignArtifactReferenceBuilder: Sendable {
    private let hasher: SHA256ContentDigester

    public init(hasher: SHA256ContentDigester = SHA256ContentDigester()) {
        self.hasher = hasher
    }

    public func makeReference(
        for write: PhysicalDesignArtifactWrite,
        rootID: ArtifactRootID
    ) throws -> PhysicalDesignArtifactBinding {
        let relativePath: ArtifactRelativePath
        do {
            relativePath = try ArtifactRelativePath(
                segments: write.relativePath.split(separator: "/").map(String.init)
            )
        } catch {
            throw PhysicalDesignStoreError.invalidPath(write.relativePath)
        }
        let digest = try hasher.digest(data: write.data, using: .sha256)
        let reference = try ArtifactReference(
            digest: digest,
            byteCount: UInt64(write.data.count),
            descriptor: ArtifactDescriptor(
            role: .output,
            kind: write.kind,
            format: write.format
            )
        )
        return try PhysicalDesignArtifactBinding(
            logicalID: write.relativePath,
            reference: reference,
            availability: .local(
                artifactID: reference.id,
                rootID: rootID,
                relativePath: relativePath
            )
        )
    }
}
