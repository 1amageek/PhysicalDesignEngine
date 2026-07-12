import Foundation

public struct PhysicalDesignMetric: Sendable, Hashable, Codable {
    public var name: String
    public var value: Double
    public var unit: String
    public var scope: String

    public init(name: String, value: Double, unit: String = "", scope: String = "design") {
        self.name = name
        self.value = value
        self.unit = unit
        self.scope = scope
    }
}
