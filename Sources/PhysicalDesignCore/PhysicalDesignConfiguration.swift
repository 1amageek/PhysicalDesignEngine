import Foundation

public struct PhysicalDesignConfiguration: Sendable, Hashable, Codable {
    public var dieWidth: Int64
    public var dieHeight: Int64
    public var coreMargin: Int64
    public var rowHeight: Int64
    public var siteWidth: Int64
    public var placementSpacing: Int64
    public var preferredRoutingLayers: [Int]
    public var maximumRoutingLayer: Int
    public var targetUtilization: Double
    public var powerNetNames: [String]
    public var maximumAntennaRatio: Double
    public var fillWindowSize: Int64
    public var fillSpacing: Int64
    public var ecoAction: PhysicalECOAction
    public var ecoTargetCellID: String?
    public var ecoTargetNetID: String?
    public var ecoDeltaX: Int64
    public var ecoDeltaY: Int64
    public var deterministicSeed: UInt64

    public init(
        dieWidth: Int64 = 1_000_000,
        dieHeight: Int64 = 1_000_000,
        coreMargin: Int64 = 100_000,
        rowHeight: Int64 = 10_000,
        siteWidth: Int64 = 1_000,
        placementSpacing: Int64 = 200,
        preferredRoutingLayers: [Int] = [2, 3, 4, 5],
        maximumRoutingLayer: Int = 6,
        targetUtilization: Double = 0.70,
        powerNetNames: [String] = ["VDD", "VSS"],
        maximumAntennaRatio: Double = 300.0,
        fillWindowSize: Int64 = 20_000,
        fillSpacing: Int64 = 2_000,
        ecoAction: PhysicalECOAction = .resizeCell,
        ecoTargetCellID: String? = nil,
        ecoTargetNetID: String? = nil,
        ecoDeltaX: Int64 = 0,
        ecoDeltaY: Int64 = 0,
        deterministicSeed: UInt64 = 0
    ) {
        self.dieWidth = dieWidth
        self.dieHeight = dieHeight
        self.coreMargin = coreMargin
        self.rowHeight = rowHeight
        self.siteWidth = siteWidth
        self.placementSpacing = placementSpacing
        self.preferredRoutingLayers = preferredRoutingLayers
        self.maximumRoutingLayer = maximumRoutingLayer
        self.targetUtilization = targetUtilization
        self.powerNetNames = powerNetNames
        self.maximumAntennaRatio = maximumAntennaRatio
        self.fillWindowSize = fillWindowSize
        self.fillSpacing = fillSpacing
        self.ecoAction = ecoAction
        self.ecoTargetCellID = ecoTargetCellID
        self.ecoTargetNetID = ecoTargetNetID
        self.ecoDeltaX = ecoDeltaX
        self.ecoDeltaY = ecoDeltaY
        self.deterministicSeed = deterministicSeed
    }

    public static let `default` = Self()

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if dieWidth <= 0 || dieHeight <= 0 {
            diagnostics.append("die dimensions must be positive")
        }
        if coreMargin < 0 || coreMargin * 2 >= min(dieWidth, dieHeight) {
            diagnostics.append("core margin must leave a positive core area")
        }
        if rowHeight <= 0 || siteWidth <= 0 || placementSpacing < 0 {
            diagnostics.append("placement grid dimensions are invalid")
        }
        if preferredRoutingLayers.isEmpty || preferredRoutingLayers.contains(where: { $0 <= 0 || $0 > maximumRoutingLayer }) {
            diagnostics.append("routing layers must be non-empty and within the maximum layer")
        }
        if targetUtilization <= 0 || targetUtilization > 1 {
            diagnostics.append("target utilization must be in the interval (0, 1]")
        }
        if powerNetNames.isEmpty || powerNetNames.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            diagnostics.append("at least one non-empty power net is required")
        }
        if maximumAntennaRatio <= 0 || fillWindowSize <= 0 || fillSpacing < 0 {
            diagnostics.append("antenna and fill configuration values are invalid")
        }
        return diagnostics
    }
}
