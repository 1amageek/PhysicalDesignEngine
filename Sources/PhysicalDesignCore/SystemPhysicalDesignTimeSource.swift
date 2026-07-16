import Foundation

public struct SystemPhysicalDesignTimeSource: PhysicalDesignTimeSource {
    public init() {}

    public var now: Date { Date.now }
}
