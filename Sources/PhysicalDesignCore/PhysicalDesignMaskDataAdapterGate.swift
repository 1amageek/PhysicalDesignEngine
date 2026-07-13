import Foundation
import CircuiteFoundation

public struct PhysicalDesignMaskDataAdapterGate: Sendable {
    public init() {}

    public func export(
        _ snapshot: PhysicalDesignSnapshot,
        format: ArtifactFormat,
        adapter: any PhysicalDesignMaskDataAdapter
    ) async throws -> Data {
        guard adapter.supportedFormat == format else {
            throw PhysicalDesignMaskDataAdapterError.unsupportedFormat(format)
        }
        guard case .qualified = adapter.qualification else {
            throw PhysicalDesignMaskDataAdapterError.adapterUnqualified(adapter.implementationID)
        }
        return try await adapter.export(snapshot)
    }
}
