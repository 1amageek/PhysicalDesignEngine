import CircuiteFoundation
import Foundation

public struct PhysicalDesignExecutableReference: Sendable, Hashable, Codable {
    public let path: String
    public let toolID: String
    public let expectedVersion: String
    public let digest: ContentDigest
    public let byteCount: UInt64

    public init(
        path: String,
        toolID: String,
        expectedVersion: String,
        digest: ContentDigest,
        byteCount: UInt64
    ) throws {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PhysicalDesignProductionConfigurationError.invalidExecutablePath
        }
        guard !toolID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !toolID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PhysicalDesignProductionConfigurationError.invalidToolID
        }
        guard !expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !expectedVersion.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PhysicalDesignProductionConfigurationError.invalidExpectedVersion
        }
        guard digest.algorithm == .sha256 else {
            throw PhysicalDesignProductionConfigurationError.invalidExecutableDigest
        }
        guard byteCount > 0 else {
            throw PhysicalDesignProductionConfigurationError.invalidExecutableByteCount
        }
        self.path = path
        self.toolID = toolID
        self.expectedVersion = expectedVersion
        self.digest = digest
        self.byteCount = byteCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            toolID: container.decode(String.self, forKey: .toolID),
            expectedVersion: container.decode(String.self, forKey: .expectedVersion),
            digest: container.decode(ContentDigest.self, forKey: .digest),
            byteCount: container.decode(UInt64.self, forKey: .byteCount)
        )
    }
}
