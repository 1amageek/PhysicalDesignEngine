import Foundation
import CircuiteFoundation

public enum PhysicalDesignMaskDataAdapterError: Error, LocalizedError, Sendable, Hashable {
    case unsupportedFormat(ArtifactFormat)
    case adapterUnqualified(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "No mask-data adapter is qualified for \(format.rawValue)."
        case .adapterUnqualified(let implementationID):
            return "Mask-data adapter \(implementationID) is not process-qualified."
        }
    }
}
