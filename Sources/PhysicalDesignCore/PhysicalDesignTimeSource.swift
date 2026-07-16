import Foundation

public protocol PhysicalDesignTimeSource: Sendable {
    var now: Date { get }
}
