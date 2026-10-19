import Foundation

public struct PhysicalDesignRepairConstraints: Sendable, Hashable, Codable {
    public var antennaStrategy: PhysicalDesignAntennaRepairStrategy
    public var minimumViaSpacing: Int64
    public var minimumFillSpacing: Int64
    public var maximumFillDensity: Double
    public var hotspotRepairMargin: Int64
    public var requireRepairVerification: Bool
    public var maximumGeometryChecks: Int?

    public init(
        antennaStrategy: PhysicalDesignAntennaRepairStrategy = .jumper,
        minimumViaSpacing: Int64 = 100,
        minimumFillSpacing: Int64 = 2_000,
        maximumFillDensity: Double = 0.25,
        hotspotRepairMargin: Int64 = 0,
        requireRepairVerification: Bool = true,
        maximumGeometryChecks: Int? = nil
    ) {
        self.antennaStrategy = antennaStrategy
        self.minimumViaSpacing = minimumViaSpacing
        self.minimumFillSpacing = minimumFillSpacing
        self.maximumFillDensity = maximumFillDensity
        self.hotspotRepairMargin = hotspotRepairMargin
        self.requireRepairVerification = requireRepairVerification
        self.maximumGeometryChecks = maximumGeometryChecks
    }

    public static let `default` = Self()

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if let maximumGeometryChecks, maximumGeometryChecks <= 0 {
            diagnostics.append("repair geometry check limit must be positive")
        }
        if minimumViaSpacing <= 0 || minimumFillSpacing < 0 {
            diagnostics.append("repair spacing values are invalid")
        }
        if !maximumFillDensity.isFinite || maximumFillDensity <= 0 || maximumFillDensity > 1 {
            diagnostics.append("maximum fill density must be in the interval (0, 1]")
        }
        if hotspotRepairMargin < 0 {
            diagnostics.append("hotspot repair margin must be non-negative")
        }
        return diagnostics
    }
}
