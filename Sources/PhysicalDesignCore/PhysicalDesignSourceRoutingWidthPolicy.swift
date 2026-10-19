/// Selects uniform caller width or the exact default WIDTH of each selected source layer.
public enum PhysicalDesignSourceRoutingWidthPolicy: String, Codable, Sendable, Hashable {
    case uniform
    case sourceDefault
}
