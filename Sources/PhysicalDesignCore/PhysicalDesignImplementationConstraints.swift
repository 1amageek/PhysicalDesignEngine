import Foundation

public struct PhysicalDesignImplementationConstraints: Sendable, Hashable, Codable {
    public var timingWeight: Double
    public var congestionWeight: Double
    public var clockTargetSkewPS: Int64
    public var clockBufferMaster: String
    public var clockRouteLayer: Int
    public var routeWidth: Int64
    public var routeSpacing: Int64
    public var trackPitch: Int64

    public init(
        timingWeight: Double = 1.0,
        congestionWeight: Double = 1.0,
        clockTargetSkewPS: Int64 = 100,
        clockBufferMaster: String = "CLKBUF_X1",
        clockRouteLayer: Int = 3,
        routeWidth: Int64 = 100,
        routeSpacing: Int64 = 100,
        trackPitch: Int64 = 100
    ) {
        self.timingWeight = timingWeight
        self.congestionWeight = congestionWeight
        self.clockTargetSkewPS = clockTargetSkewPS
        self.clockBufferMaster = clockBufferMaster
        self.clockRouteLayer = clockRouteLayer
        self.routeWidth = routeWidth
        self.routeSpacing = routeSpacing
        self.trackPitch = trackPitch
    }

    public static let `default` = Self()

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if !timingWeight.isFinite || timingWeight < 0 {
            diagnostics.append("timing weight must be finite and non-negative")
        }
        if !congestionWeight.isFinite || congestionWeight < 0 {
            diagnostics.append("congestion weight must be finite and non-negative")
        }
        if clockTargetSkewPS < 0 || clockRouteLayer <= 0 {
            diagnostics.append("clock skew target and route layer must be positive")
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
