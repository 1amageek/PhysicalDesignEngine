import Foundation
import CircuiteFoundation

public actor InMemoryPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    private var dataByPath: [String: Data] = [:]
    private let hasher: SHA256ContentDigester
    private let referenceBuilder: PhysicalDesignArtifactReferenceBuilder

    public init(hasher: SHA256ContentDigester = SHA256ContentDigester()) {
        self.hasher = hasher
        self.referenceBuilder = PhysicalDesignArtifactReferenceBuilder(hasher: hasher)
    }

    public func registerInput(
        _ data: Data,
        relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        let location: ArtifactLocation
        do {
            location = try ArtifactLocation(workspaceRelativePath: relativePath)
        } catch {
            throw PhysicalDesignStoreError.invalidPath(relativePath)
        }
        guard dataByPath[relativePath] == nil else {
            throw PhysicalDesignStoreError.pathAlreadyExists(relativePath)
        }
        let digest = try hasher.digest(data: data, using: .sha256)
        let inputReference = ArtifactReference(
            locator: ArtifactLocator(
                location: location,
                role: .input,
                kind: kind,
                format: format
            ),
            digest: digest,
            byteCount: UInt64(data.count)
        )
        dataByPath[relativePath] = data
        return inputReference
    }

    public func read(_ reference: ArtifactReference) async throws -> Data {
        guard let data = dataByPath[reference.path] else {
            throw PhysicalDesignStoreError.readFailed("artifact does not exist: \(reference.path)")
        }
        if UInt64(data.count) != reference.byteCount {
            throw PhysicalDesignStoreError.readFailed("\(reference.path): byte count does not match the reference")
        }
        let actualDigest = try hasher.digest(
            data: data,
            using: reference.digest.algorithm
        )
        if actualDigest != reference.digest {
            throw PhysicalDesignStoreError.readFailed("\(reference.path): SHA-256 digest does not match the reference")
        }
        return data
    }

    public func write(
        _ artifacts: [PhysicalDesignArtifactWrite]
    ) async throws -> [ArtifactReference] {
        var uniquePaths = Set<String>()
        let references = try artifacts.map { artifact in
            guard uniquePaths.insert(artifact.relativePath).inserted else {
                throw PhysicalDesignStoreError.invalidPath(
                    "duplicate batch path: \(artifact.relativePath)"
                )
            }
            let reference = try referenceBuilder.makeReference(for: artifact)
            if let existingData = dataByPath[artifact.relativePath] {
                guard existingData == artifact.data else {
                    throw PhysicalDesignStoreError.pathAlreadyExists(artifact.relativePath)
                }
            }
            return reference
        }
        for artifact in artifacts {
            dataByPath[artifact.relativePath] = artifact.data
        }
        return references
    }

    public func data(at path: String) -> Data? {
        dataByPath[path]
    }
}
