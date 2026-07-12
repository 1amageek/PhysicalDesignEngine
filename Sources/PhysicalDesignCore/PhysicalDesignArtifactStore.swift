import Foundation
import XcircuitePackage

public protocol PhysicalDesignArtifactStore: Sendable {
    func read(_ reference: XcircuiteFileReference) async throws -> Data

    func write(
        _ data: Data,
        relativePath: String,
        kind: XcircuiteFileKind,
        format: XcircuiteFileFormat,
        runID: String
    ) async throws -> XcircuiteFileReference
}
