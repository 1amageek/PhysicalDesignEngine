import Foundation

public struct PhysicalDesignImplementationConstraints: Sendable, Hashable, Codable {
    public var wirelengthWeight: Double
    public var congestionWeight: Double
    public var clockBufferDistanceThresholdDBU: Int64
    public var clockRouteMaximumLengthDBU: Int64
    public var clockBufferMaster: String
    public var clockRouteLayer: Int
    public var routeWidth: Int64
    public var routeSpacing: Int64
    public var trackPitch: Int64

    public init(
        wirelengthWeight: Double = 1.0,
        congestionWeight: Double = 1.0,
        clockBufferDistanceThresholdDBU: Int64 = 10_000,
        clockRouteMaximumLengthDBU: Int64 = 40_000,
        clockBufferMaster: String = "CLKBUF_X1",
        clockRouteLayer: Int = 3,
        routeWidth: Int64 = 100,
        routeSpacing: Int64 = 100,
        trackPitch: Int64 = 100
    ) {
        self.wirelengthWeight = wirelengthWeight
        self.congestionWeight = congestionWeight
        self.clockBufferDistanceThresholdDBU = clockBufferDistanceThresholdDBU
        self.clockRouteMaximumLengthDBU = clockRouteMaximumLengthDBU
        self.clockBufferMaster = clockBufferMaster
        self.clockRouteLayer = clockRouteLayer
        self.routeWidth = routeWidth
        self.routeSpacing = routeSpacing
        self.trackPitch = trackPitch
    }

    public static let `default` = Self()

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if !wirelengthWeight.isFinite || wirelengthWeight < 0 {
            diagnostics.append("wirelength weight must be finite and non-negative")
        }
        if !congestionWeight.isFinite || congestionWeight < 0 {
            diagnostics.append("congestion weight must be finite and non-negative")
        }
        if clockBufferDistanceThresholdDBU < 0
            || clockRouteMaximumLengthDBU <= 0
            || clockRouteLayer <= 0 {
            diagnostics.append("clock geometry limits and route layer must be positive")
        }
        if clockBufferMaster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append("clock buffer master must be non-empty")
        }
        if routeWidth <= 0 || routeSpacing < 0 || trackPitch <= 0 {
            diagnostics.append("route width, spacing and track pitch are invalid")
        }
        return diagnostics
    }
}
