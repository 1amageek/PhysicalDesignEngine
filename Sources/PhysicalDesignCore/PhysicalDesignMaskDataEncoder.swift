import Foundation
import CircuiteFoundation

public protocol PhysicalDesignMaskDataEncoder: Sendable {
    var supportedFormat: ArtifactFormat { get }
    var implementationID: String { get }

    func encode(_ snapshot: PhysicalDesignSnapshot) async throws -> Data
}
