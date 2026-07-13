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
    public var implementationConstraints: PhysicalDesignImplementationConstraints?
    public var repairConstraints: PhysicalDesignRepairConstraints?

    private enum CodingKeys: String, CodingKey {
        case dieWidth
        case dieHeight
        case coreMargin
        case rowHeight
        case siteWidth
        case placementSpacing
        case preferredRoutingLayers
        case maximumRoutingLayer
        case targetUtilization
        case powerNetNames
        case maximumAntennaRatio
        case fillWindowSize
        case fillSpacing
        case ecoAction
        case ecoTargetCellID
        case ecoTargetNetID
        case ecoDeltaX
        case ecoDeltaY
        case deterministicSeed
        case implementationConstraints
        case repairConstraints
    }

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
        deterministicSeed: UInt64 = 0,
        implementationConstraints: PhysicalDesignImplementationConstraints? = .default,
        repairConstraints: PhysicalDesignRepairConstraints? = .default
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
        self.implementationConstraints = implementationConstraints
        self.repairConstraints = repairConstraints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dieWidth = try container.decodeIfPresent(Int64.self, forKey: .dieWidth) ?? 1_000_000
        dieHeight = try container.decodeIfPresent(Int64.self, forKey: .dieHeight) ?? 1_000_000
        coreMargin = try container.decodeIfPresent(Int64.self, forKey: .coreMargin) ?? 100_000
        rowHeight = try container.decodeIfPresent(Int64.self, forKey: .rowHeight) ?? 10_000
        siteWidth = try container.decodeIfPresent(Int64.self, forKey: .siteWidth) ?? 1_000
        placementSpacing = try container.decodeIfPresent(Int64.self, forKey: .placementSpacing) ?? 200
        preferredRoutingLayers = try container.decodeIfPresent([Int].self, forKey: .preferredRoutingLayers) ?? [2, 3, 4, 5]
        maximumRoutingLayer = try container.decodeIfPresent(Int.self, forKey: .maximumRoutingLayer) ?? 6
        targetUtilization = try container.decodeIfPresent(Double.self, forKey: .targetUtilization) ?? 0.70
        powerNetNames = try container.decodeIfPresent([String].self, forKey: .powerNetNames) ?? ["VDD", "VSS"]
        maximumAntennaRatio = try container.decodeIfPresent(Double.self, forKey: .maximumAntennaRatio) ?? 300.0
        fillWindowSize = try container.decodeIfPresent(Int64.self, forKey: .fillWindowSize) ?? 20_000
        fillSpacing = try container.decodeIfPresent(Int64.self, forKey: .fillSpacing) ?? 2_000
        ecoAction = try container.decodeIfPresent(PhysicalECOAction.self, forKey: .ecoAction) ?? .resizeCell
        ecoTargetCellID = try container.decodeIfPresent(String.self, forKey: .ecoTargetCellID)
        ecoTargetNetID = try container.decodeIfPresent(String.self, forKey: .ecoTargetNetID)
        ecoDeltaX = try container.decodeIfPresent(Int64.self, forKey: .ecoDeltaX) ?? 0
        ecoDeltaY = try container.decodeIfPresent(Int64.self, forKey: .ecoDeltaY) ?? 0
        deterministicSeed = try container.decodeIfPresent(UInt64.self, forKey: .deterministicSeed) ?? 0
        implementationConstraints = try container.decodeIfPresent(PhysicalDesignImplementationConstraints.self, forKey: .implementationConstraints) ?? .default
        repairConstraints = try container.decodeIfPresent(PhysicalDesignRepairConstraints.self, forKey: .repairConstraints) ?? .default
    }

    public static let `default` = Self()

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if dieWidth <= 0 || dieHeight <= 0 {
            diagnostics.append("die dimensions must be positive")
        }
        let minimumDieDimension = min(dieWidth, dieHeight)
        let (doubleCoreMargin, coreMarginOverflow) = coreMargin.multipliedReportingOverflow(by: 2)
        if coreMargin < 0 || coreMarginOverflow || doubleCoreMargin >= minimumDieDimension {
            diagnostics.append("core margin must leave a positive core area")
        }
        if rowHeight <= 0 || siteWidth <= 0 || placementSpacing < 0 {
            diagnostics.append("placement grid dimensions are invalid")
        }
        if maximumRoutingLayer <= 0 {
            diagnostics.append("maximum routing layer must be positive")
        }
        if preferredRoutingLayers.isEmpty || preferredRoutingLayers.contains(where: { $0 <= 0 || $0 > maximumRoutingLayer }) {
            diagnostics.append("routing layers must be non-empty and within the maximum layer")
        }
        if Set(preferredRoutingLayers).count != preferredRoutingLayers.count {
            diagnostics.append("routing layers must be unique")
        }
        if !preferredRoutingLayers.contains(where: { !$0.isMultiple(of: 2) }) {
            diagnostics.append("at least one odd routing layer is required for horizontal segments")
        }
        if !preferredRoutingLayers.contains(where: { $0.isMultiple(of: 2) }) {
            diagnostics.append("at least one even routing layer is required for vertical segments")
        }
        if targetUtilization <= 0 || targetUtilization > 1 {
            diagnostics.append("target utilization must be in the interval (0, 1]")
        }
        if powerNetNames.isEmpty || powerNetNames.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            diagnostics.append("at least one non-empty power net is required")
        }
        if Set(powerNetNames).count != powerNetNames.count {
            diagnostics.append("power net names must be unique")
        }
        if maximumAntennaRatio <= 0 || fillWindowSize <= 0 || fillSpacing < 0 {
            diagnostics.append("antenna and fill configuration values are invalid")
        }
        if siteWidth > Int64.max / 10 {
            diagnostics.append("site width is too large for native power-structure pitch calculations")
        }
        let minimumFillSpacing = repairConstraints?.minimumFillSpacing ?? PhysicalDesignRepairConstraints.default.minimumFillSpacing
        let (_, fillStepOverflow) = fillWindowSize.addingReportingOverflow(max(fillSpacing, minimumFillSpacing))
        if fillStepOverflow {
            diagnostics.append("fill grid step overflows the coordinate range")
        }
        if let implementationConstraints {
            diagnostics.append(contentsOf: implementationConstraints.validationDiagnostics())
        }
        if let repairConstraints {
            diagnostics.append(contentsOf: repairConstraints.validationDiagnostics())
        }
        return diagnostics
    }
}
