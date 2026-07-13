import Foundation
import CircuiteFoundation

public protocol PhysicalDesignMaskDataAdapter: Sendable {
    var supportedFormat: ArtifactFormat { get }
    var implementationID: String { get }
    var qualification: PhysicalDesignMaskDataAdapterQualification { get }

    func export(_ snapshot: PhysicalDesignSnapshot) async throws -> Data
}
