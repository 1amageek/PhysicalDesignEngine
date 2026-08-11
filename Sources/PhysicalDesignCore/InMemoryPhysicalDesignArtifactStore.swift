import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto

public actor InMemoryPhysicalDesignArtifactStore: PhysicalDesignArtifactStore {
    private var dataByPath: [String: Data] = [:]
    private let hasher: SHA256ContentDigester
    private let referenceBuilder: PhysicalDesignArtifactReferenceBuilder
    private let rootID: ArtifactRootID

    public init(hasher: SHA256ContentDigester = SHA256ContentDigester()) {
        do {
            self.rootID = try ArtifactRootID(rawValue: "physical-design-memory")
        } catch {
            preconditionFailure("The static physical-design memory root ID is invalid: \(error)")
        }
        self.hasher = hasher
        self.referenceBuilder = PhysicalDesignArtifactReferenceBuilder(hasher: hasher)
    }

    public func registerInput(
        _ data: Data,
        relativePath: String,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> PhysicalDesignArtifactBinding {
        let relativeArtifactPath: ArtifactRelativePath
        do {
            relativeArtifactPath = try ArtifactRelativePath(
                segments: relativePath.split(separator: "/").map(String.init)
            )
        } catch {
            throw PhysicalDesignStoreError.invalidPath(relativePath)
        }
        guard dataByPath[relativePath] == nil else {
            throw PhysicalDesignStoreError.pathAlreadyExists(relativePath)
        }
        let digest = try hasher.digest(data: data, using: .sha256)
        let reference = try ArtifactReference(
            digest: digest,
            byteCount: UInt64(data.count),
            descriptor: ArtifactDescriptor(
                role: .input,
                kind: kind,
                format: format
            )
        )
        let inputReference = try PhysicalDesignArtifactBinding(
            logicalID: relativePath,
            reference: reference,
            availability: .local(
                artifactID: reference.id,
                rootID: rootID,
                relativePath: relativeArtifactPath
            )
        )
        dataByPath[relativePath] = data
        return inputReference
    }

    public func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
        let reference = binding.reference
        guard let data = dataByPath[binding.path] else {
            throw PhysicalDesignStoreError.readFailed("artifact does not exist: \(binding.path)")
        }
        if UInt64(data.count) != reference.byteCount {
            throw PhysicalDesignStoreError.readFailed("\(binding.path): byte count does not match the reference")
        }
        let actualDigest = try hasher.digest(
            data: data,
            using: reference.digest.algorithm
        )
        if actualDigest != reference.digest {
            throw PhysicalDesignStoreError.readFailed("\(binding.path): SHA-256 digest does not match the reference")
        }
        return data
    }

    public func write(
        _ artifacts: [PhysicalDesignArtifactWrite]
    ) async throws -> [PhysicalDesignArtifactBinding] {
        var uniquePaths = Set<String>()
        let references = try artifacts.map { artifact in
            guard uniquePaths.insert(artifact.relativePath).inserted else {
                throw PhysicalDesignStoreError.invalidPath(
                    "duplicate batch path: \(artifact.relativePath)"
                )
            }
            let reference = try referenceBuilder.makeReference(for: artifact, rootID: rootID)
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
