import Foundation
import XcircuitePackage

public protocol PhysicalDesignMaskDataAdapter: Sendable {
    var supportedFormat: XcircuiteFileFormat { get }
    var implementationID: String { get }
    var qualification: PhysicalDesignMaskDataAdapterQualification { get }

    func export(_ snapshot: PhysicalDesignSnapshot) async throws -> Data
}
