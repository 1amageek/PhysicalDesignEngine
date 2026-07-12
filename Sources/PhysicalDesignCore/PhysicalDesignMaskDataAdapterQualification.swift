import Foundation

public enum PhysicalDesignMaskDataAdapterQualification: Sendable, Hashable, Codable {
    case unqualified
    case qualified(processID: String, version: String)
}
