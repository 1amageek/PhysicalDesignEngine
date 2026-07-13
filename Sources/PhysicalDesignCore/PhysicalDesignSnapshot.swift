import Foundation

public struct PhysicalDesignSnapshot: Sendable, Hashable, Codable {
    public struct Rect: Sendable, Hashable, Codable {
        public var x: Int64
        public var y: Int64
        public var width: Int64
        public var height: Int64

        public init(x: Int64, y: Int64, width: Int64, height: Int64) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Int64 {
            let (value, overflow) = x.addingReportingOverflow(width)
            guard overflow else { return value }
            return width >= 0 ? .max : .min
        }

        public var maxY: Int64 {
            let (value, overflow) = y.addingReportingOverflow(height)
            guard overflow else { return value }
            return height >= 0 ? .max : .min
        }

        public func contains(_ other: Rect) -> Bool {
            other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
        }

        public func containsPoint(x pointX: Int64, y pointY: Int64) -> Bool {
            pointX >= x && pointX <= maxX && pointY >= y && pointY <= maxY
        }

        public func intersects(_ other: Rect) -> Bool {
            x < other.maxX && maxX > other.x && y < other.maxY && maxY > other.y
        }

        public func expanded(by margin: Int64) -> Rect {
            let (doubleMargin, marginOverflow) = margin.multipliedReportingOverflow(by: 2)
            let (expandedWidth, widthOverflow) = width.addingReportingOverflow(doubleMargin)
            let (expandedHeight, heightOverflow) = height.addingReportingOverflow(doubleMargin)
            let (expandedX, xOverflow) = x.subtractingReportingOverflow(margin)
            let (expandedY, yOverflow) = y.subtractingReportingOverflow(margin)
            return Rect(
                x: xOverflow ? (margin >= 0 ? .min : .max) : expandedX,
                y: yOverflow ? (margin >= 0 ? .min : .max) : expandedY,
                width: marginOverflow || widthOverflow ? (margin >= 0 ? .max : .min) : expandedWidth,
                height: marginOverflow || heightOverflow ? (margin >= 0 ? .max : .min) : expandedHeight
            )
        }
    }

    public struct Row: Sendable, Hashable, Codable {
        public var id: String
        public var originX: Int64
        public var originY: Int64
        public var siteWidth: Int64
        public var height: Int64
        public var siteCount: Int64

        public init(
            id: String,
            originX: Int64,
            originY: Int64,
            siteWidth: Int64,
            height: Int64,
            siteCount: Int64
        ) {
            self.id = id
            self.originX = originX
            self.originY = originY
            self.siteWidth = siteWidth
            self.height = height
            self.siteCount = siteCount
        }
    }

    public struct Cell: Sendable, Hashable, Codable {
        public var id: String
        public var master: String
        public var x: Int64
        public var y: Int64
        public var width: Int64
        public var height: Int64
        public var placed: Bool
        public var locked: Bool
        public var isClockBuffer: Bool
        public var isFiller: Bool

        public init(
            id: String,
            master: String,
            x: Int64 = 0,
            y: Int64 = 0,
            width: Int64 = 1_000,
            height: Int64 = 10_000,
            placed: Bool = false,
            locked: Bool = false,
            isClockBuffer: Bool = false,
            isFiller: Bool = false
        ) {
            self.id = id
            self.master = master
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.placed = placed
            self.locked = locked
            self.isClockBuffer = isClockBuffer
            self.isFiller = isFiller
        }
    }

    public struct Pin: Sendable, Hashable, Codable {
        public var id: String
        public var cellID: String?
        public var name: String
        public var x: Int64
        public var y: Int64
        public var netID: String?
        public var direction: String

        public init(
            id: String,
            cellID: String? = nil,
            name: String,
            x: Int64 = 0,
            y: Int64 = 0,
            netID: String? = nil,
            direction: String = "input"
        ) {
            self.id = id
            self.cellID = cellID
            self.name = name
            self.x = x
            self.y = y
            self.netID = netID
            self.direction = direction
        }
    }

    public struct Net: Sendable, Hashable, Codable {
        public var id: String
        public var pinIDs: [String]
        public var isClock: Bool
        public var antennaRatio: Double?
        public var maximumAntennaRatio: Double?

        public init(
            id: String,
            pinIDs: [String],
            isClock: Bool = false,
            antennaRatio: Double? = nil,
            maximumAntennaRatio: Double? = nil
        ) {
            self.id = id
            self.pinIDs = pinIDs
            self.isClock = isClock
            self.antennaRatio = antennaRatio
            self.maximumAntennaRatio = maximumAntennaRatio
        }
    }

    public struct RouteSegment: Sendable, Hashable, Codable {
        public var id: String
        public var layer: Int
        public var x1: Int64
        public var y1: Int64
        public var x2: Int64
        public var y2: Int64
        public var isJumper: Bool

        public init(
            id: String,
            layer: Int,
            x1: Int64,
            y1: Int64,
            x2: Int64,
            y2: Int64,
            isJumper: Bool = false
        ) {
            self.id = id
            self.layer = layer
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
            self.isJumper = isJumper
        }
    }

    public struct Route: Sendable, Hashable, Codable {
        public var id: String
        public var netID: String
        public var segments: [RouteSegment]

        public init(id: String, netID: String, segments: [RouteSegment]) {
            self.id = id
            self.netID = netID
            self.segments = segments
        }
    }

    public struct PowerStructure: Sendable, Hashable, Codable {
        public var id: String
        public var netID: String
        public var kind: String
        public var layer: Int
        public var geometry: Rect

        public init(id: String, netID: String, kind: String, layer: Int, geometry: Rect) {
            self.id = id
            self.netID = netID
            self.kind = kind
            self.layer = layer
            self.geometry = geometry
        }
    }

    public struct ClockTree: Sendable, Hashable, Codable {
        public var id: String
        public var netID: String
        public var sourcePinID: String
        public var sinkPinIDs: [String]
        public var bufferCellIDs: [String]
        public var estimatedSkewPS: Int64
        public var estimatedLatencyPS: Int64

        public init(
            id: String,
            netID: String,
            sourcePinID: String,
            sinkPinIDs: [String],
            bufferCellIDs: [String] = [],
            estimatedSkewPS: Int64 = 0,
            estimatedLatencyPS: Int64 = 0
        ) {
            self.id = id
            self.netID = netID
            self.sourcePinID = sourcePinID
            self.sinkPinIDs = sinkPinIDs
            self.bufferCellIDs = bufferCellIDs
            self.estimatedSkewPS = estimatedSkewPS
            self.estimatedLatencyPS = estimatedLatencyPS
        }
    }

    public struct Via: Sendable, Hashable, Codable {
        public var id: String
        public var netID: String
        public var x: Int64
        public var y: Int64
        public var lowerLayer: Int
        public var upperLayer: Int
        public var isRedundant: Bool

        public init(
            id: String,
            netID: String,
            x: Int64,
            y: Int64,
            lowerLayer: Int,
            upperLayer: Int,
            isRedundant: Bool = false
        ) {
            self.id = id
            self.netID = netID
            self.x = x
            self.y = y
            self.lowerLayer = lowerLayer
            self.upperLayer = upperLayer
            self.isRedundant = isRedundant
        }
    }

    public struct Fill: Sendable, Hashable, Codable {
        public var id: String
        public var layer: Int
        public var geometry: Rect

        public init(id: String, layer: Int, geometry: Rect) {
            self.id = id
            self.layer = layer
            self.geometry = geometry
        }
    }

    public struct Hotspot: Sendable, Hashable, Codable {
        public var id: String
        public var geometry: Rect
        public var severity: String
        public var resolved: Bool
        public var resolution: String?

        public init(
            id: String,
            geometry: Rect,
            severity: String,
            resolved: Bool = false,
            resolution: String? = nil
        ) {
            self.id = id
            self.geometry = geometry
            self.severity = severity
            self.resolved = resolved
            self.resolution = resolution
        }
    }

    public struct AntennaRepair: Sendable, Hashable, Codable {
        public var id: String
        public var netID: String
        public var strategy: String
        public var previousRatio: Double
        public var resultingRatio: Double

        public init(
            id: String,
            netID: String,
            strategy: String,
            previousRatio: Double,
            resultingRatio: Double
        ) {
            self.id = id
            self.netID = netID
            self.strategy = strategy
            self.previousRatio = previousRatio
            self.resultingRatio = resultingRatio
        }
    }

    public var schemaVersion: Int
    public var topCell: String
    public var unitsPerMicron: Int
    public var die: Rect?
    public var core: Rect?
    public var rows: [Row]
    public var cells: [Cell]
    public var pins: [Pin]
    public var nets: [Net]
    public var blockages: [Rect]
    public var powerStructures: [PowerStructure]
    public var clockTrees: [ClockTree]
    public var routes: [Route]
    public var vias: [Via]
    public var fills: [Fill]
    public var hotspots: [Hotspot]
    public var antennaRepairs: [AntennaRepair]
    public var metadata: [String: String]
    public var implementationState: PhysicalDesignImplementationState?

    public init(
        schemaVersion: Int = 1,
        topCell: String,
        unitsPerMicron: Int = 1_000,
        die: Rect? = nil,
        core: Rect? = nil,
        rows: [Row] = [],
        cells: [Cell] = [],
        pins: [Pin] = [],
        nets: [Net] = [],
        blockages: [Rect] = [],
        powerStructures: [PowerStructure] = [],
        clockTrees: [ClockTree] = [],
        routes: [Route] = [],
        vias: [Via] = [],
        fills: [Fill] = [],
        hotspots: [Hotspot] = [],
        antennaRepairs: [AntennaRepair] = [],
        metadata: [String: String] = [:],
        implementationState: PhysicalDesignImplementationState? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.topCell = topCell
        self.unitsPerMicron = unitsPerMicron
        self.die = die
        self.core = core
        self.rows = rows
        self.cells = cells
        self.pins = pins
        self.nets = nets
        self.blockages = blockages
        self.powerStructures = powerStructures
        self.clockTrees = clockTrees
        self.routes = routes
        self.vias = vias
        self.fills = fills
        self.hotspots = hotspots
        self.antennaRepairs = antennaRepairs
        self.metadata = metadata
        self.implementationState = implementationState
    }

    public static func empty(topCell: String) -> Self {
        Self(topCell: topCell)
    }

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if schemaVersion != 1 {
            diagnostics.append("unsupported physical snapshot schema version")
        }
        if topCell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append("top cell is empty")
        }
        if unitsPerMicron <= 0 {
            diagnostics.append("units per micron must be positive")
        }
        if let die, !isValid(die) {
            diagnostics.append("die rectangle is invalid")
        }
        if let core, !isValid(core) {
            diagnostics.append("core rectangle is invalid")
        }
        if let die, let core, !die.contains(core) {
            diagnostics.append("core rectangle must be contained in the die rectangle")
        }
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: cells.map(\.id), kind: "cell"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: pins.map(\.id), kind: "pin"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: nets.map(\.id), kind: "net"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: rows.map(\.id), kind: "row"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: routes.map(\.id), kind: "route"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: vias.map(\.id), kind: "via"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: fills.map(\.id), kind: "fill"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: hotspots.map(\.id), kind: "hotspot"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: powerStructures.map(\.id), kind: "power structure"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: clockTrees.map(\.id), kind: "clock tree"))
        diagnostics.append(contentsOf: duplicateDiagnostics(ids: antennaRepairs.map(\.id), kind: "antenna repair"))
        let netIDs = Set(nets.map(\.id))
        let pinIDs = Set(pins.map(\.id))
        let cellIDs = Set(cells.map(\.id))
        var routeSegmentIDs: Set<String> = []
        var clockConstraintIDs: Set<String> = []
        var trackIDs: Set<String> = []
        var powerDomainIDs: Set<String> = []
        var padIDs: Set<String> = []

        for row in rows {
            let (rowWidth, rowWidthOverflow) = row.siteCount.multipliedReportingOverflow(by: row.siteWidth)
            if row.siteWidth <= 0 || row.height <= 0 || row.siteCount <= 0 || rowWidthOverflow
                || !hasValidExtent(origin: row.originX, length: rowWidth) {
                diagnostics.append("row \(row.id) has invalid geometry")
            }
        }
        if let core {
            for row in rows {
                let (rowWidth, rowWidthOverflow) = row.siteCount.multipliedReportingOverflow(by: row.siteWidth)
                guard !rowWidthOverflow else { continue }
                let rowGeometry = Rect(
                    x: row.originX,
                    y: row.originY,
                    width: row.siteCount > 0 ? rowWidth : 0,
                    height: row.height
                )
                if isValid(rowGeometry) && !core.contains(rowGeometry) {
                    diagnostics.append("row \(row.id) is outside the core rectangle")
                }
            }
        }
        for cell in cells {
            if cell.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cell.master.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnostics.append("cell \(cell.id) has incomplete identity")
            }
            if cell.width <= 0 || cell.height <= 0 {
                diagnostics.append("cell \(cell.id) has invalid geometry")
            }
        }
        for pin in pins {
            if let cellID = pin.cellID, !cellIDs.contains(cellID) {
                diagnostics.append("pin \(pin.id) refers to missing cell \(cellID)")
            }
            if pin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnostics.append("pin \(pin.id) has an empty name")
            }
            if pin.direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnostics.append("pin \(pin.id) has an empty direction")
            }
            if let netID = pin.netID, netID != "UNCONNECTED", !netIDs.contains(netID) {
                diagnostics.append("pin \(pin.id) refers to missing net \(netID)")
            }
        }
        for net in nets {
            let missingPins = net.pinIDs.filter { !pinIDs.contains($0) }
            if !missingPins.isEmpty {
                diagnostics.append("net \(net.id) refers to missing pins \(missingPins.sorted().joined(separator: ","))")
            }
            if Set(net.pinIDs).count != net.pinIDs.count {
                diagnostics.append("net \(net.id) contains duplicate pin references")
            }
            if net.antennaRatio != nil && !(net.antennaRatio?.isFinite ?? false) {
                diagnostics.append("net \(net.id) has a non-finite antenna ratio")
            }
            if let maximumAntennaRatio = net.maximumAntennaRatio,
               !maximumAntennaRatio.isFinite || maximumAntennaRatio <= 0 {
                diagnostics.append("net \(net.id) has an invalid maximum antenna ratio")
            }
            for pinID in net.pinIDs {
                if let pinNetID = pins.first(where: { $0.id == pinID })?.netID,
                   pinNetID != "UNCONNECTED", pinNetID != net.id {
                    diagnostics.append("pin \(pinID) is assigned to net \(pinNetID) but listed on net \(net.id)")
                }
            }
        }
        for route in routes {
            if !netIDs.contains(route.netID) {
                diagnostics.append("route \(route.id) refers to missing net \(route.netID)")
            }
            if route.segments.isEmpty {
                diagnostics.append("route \(route.id) has no segments")
            }
            for segment in route.segments {
                if segment.layer <= 0 || (segment.x1 == segment.x2 && segment.y1 == segment.y2) || (segment.x1 != segment.x2 && segment.y1 != segment.y2) {
                    diagnostics.append("route segment \(segment.id) has invalid orthogonal geometry")
                }
                if !routeSegmentIDs.insert(segment.id).inserted {
                    diagnostics.append("duplicate route segment identifier \(segment.id)")
                }
            }
        }
        for pin in pins {
            guard let netID = pin.netID, netID != "UNCONNECTED" else { continue }
            if let net = nets.first(where: { $0.id == netID }), !net.pinIDs.contains(pin.id) {
                diagnostics.append("pin \(pin.id) is not listed in its assigned net \(netID)")
            }
        }
        for via in vias {
            if via.lowerLayer <= 0 || via.upperLayer <= via.lowerLayer {
                diagnostics.append("via \(via.id) has invalid layer ordering")
            }
            if !netIDs.contains(via.netID) {
                diagnostics.append("via \(via.id) refers to missing net \(via.netID)")
            }
            if let core, !core.containsPoint(x: via.x, y: via.y) {
                diagnostics.append("via \(via.id) is outside the core rectangle")
            }
        }
        for fill in fills {
            if fill.layer <= 0 || !isValid(fill.geometry) {
                diagnostics.append("fill \(fill.id) has invalid geometry")
            }
            if let core, !core.contains(fill.geometry) {
                diagnostics.append("fill \(fill.id) is outside the core rectangle")
            }
        }
        for hotspot in hotspots {
            if hotspot.severity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isValid(hotspot.geometry) {
                diagnostics.append("hotspot \(hotspot.id) has invalid geometry or severity")
            }
            if hotspot.resolved && hotspot.resolution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                diagnostics.append("resolved hotspot \(hotspot.id) has no resolution")
            }
        }
        for blockage in blockages where !isValid(blockage) {
            diagnostics.append("placement blockage has invalid geometry")
        }
        for structure in powerStructures {
            if structure.netID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || structure.layer <= 0
                || structure.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !isValid(structure.geometry) {
                diagnostics.append("power structure \(structure.id) is invalid")
            }
        }
        for repair in antennaRepairs {
            if !netIDs.contains(repair.netID) || repair.strategy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !repair.previousRatio.isFinite || !repair.resultingRatio.isFinite
                || repair.previousRatio < 0 || repair.resultingRatio < 0
                || repair.resultingRatio > repair.previousRatio {
                diagnostics.append("antenna repair \(repair.id) is invalid")
            }
        }
        for tree in clockTrees {
            guard let net = nets.first(where: { $0.id == tree.netID }) else {
                diagnostics.append("clock tree \(tree.id) refers to missing net \(tree.netID)")
                continue
            }
            if !net.isClock {
                diagnostics.append("clock tree \(tree.id) refers to a non-clock net")
            }
            if !pinIDs.contains(tree.sourcePinID) || !net.pinIDs.contains(tree.sourcePinID) {
                diagnostics.append("clock tree \(tree.id) has an invalid source pin")
            }
            let clockFamilyNets = nets.filter { $0.id == tree.netID || $0.id.hasPrefix("\(tree.netID)_branch_") }
            for sinkPinID in tree.sinkPinIDs where !pinIDs.contains(sinkPinID) || !clockFamilyNets.contains(where: { $0.pinIDs.contains(sinkPinID) }) {
                diagnostics.append("clock tree \(tree.id) has an invalid sink pin \(sinkPinID)")
            }
            for bufferCellID in tree.bufferCellIDs {
                guard let buffer = cells.first(where: { $0.id == bufferCellID }), buffer.isClockBuffer else {
                    diagnostics.append("clock tree \(tree.id) has an invalid buffer cell \(bufferCellID)")
                    continue
                }
            }
            if tree.estimatedSkewPS < 0 || tree.estimatedLatencyPS < 0 {
                diagnostics.append("clock tree \(tree.id) has negative timing estimates")
            }
        }
        if let implementationState {
            diagnostics.append(contentsOf: implementationState.tracks.flatMap { track in
                if !trackIDs.insert(track.id).inserted {
                    return ["duplicate track identifier \(track.id)"]
                }
                return track.layer <= 0 || track.spacing <= 0 || track.count <= 0
                    || (track.direction.lowercased() != "horizontal" && track.direction.lowercased() != "vertical")
                    ? ["track \(track.id) has invalid geometry"] : []
            })
            diagnostics.append(contentsOf: implementationState.powerDomains.flatMap { domain in
                if !powerDomainIDs.insert(domain.id).inserted {
                    return ["duplicate power domain identifier \(domain.id)"]
                }
                return domain.netIDs.isEmpty || !isValid(domain.geometry) ? ["power domain \(domain.id) is invalid"] : []
            })
            diagnostics.append(contentsOf: implementationState.pads.flatMap { pad in
                if !padIDs.insert(pad.id).inserted {
                    return ["duplicate pad identifier \(pad.id)"]
                }
                if !pinIDs.contains(pad.pinID) {
                    return ["pad \(pad.id) refers to missing pin \(pad.pinID)"]
                }
                if let die, !die.contains(pad.geometry) {
                    return ["pad \(pad.id) is outside the die rectangle"]
                }
                return pad.pinID.isEmpty || !isValid(pad.geometry) ? ["pad \(pad.id) is invalid"] : []
            })
            for constraint in implementationState.clockRouteConstraints {
                if !clockConstraintIDs.insert(constraint.id).inserted {
                    diagnostics.append("duplicate clock route constraint identifier \(constraint.id)")
                }
                if constraint.layer <= 0 || constraint.width <= 0 || constraint.spacing < 0
                    || constraint.maximumLength.map({ $0 <= 0 }) == true
                    || constraint.maximumTransitionPS.map({ $0 <= 0 }) == true
                    || !netIDs.contains(constraint.netID) {
                    diagnostics.append("clock route constraint \(constraint.id) is invalid")
                }
            }
            if let routingEvidence = implementationState.routingEvidence {
                if routingEvidence.mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || routingEvidence.routedNetCount < 0
                    || routingEvidence.blockageConflictCount < 0
                    || routingEvidence.layerDirectionViolations < 0
                    || routingEvidence.spacingConflicts < 0
                    || routingEvidence.viaCount < 0 {
                    diagnostics.append("routing evidence is invalid")
                }
            }
            for proof in implementationState.repairProofs {
                if proof.stage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || proof.strategy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || proof.violationsBefore < 0 || proof.violationsAfter < 0
                    || (proof.verified && proof.violationsAfter != 0) {
                    diagnostics.append("repair proof \(proof.stage)/\(proof.strategy) is invalid")
                }
            }
            if let proof = implementationState.placementProof {
                if proof.cellCount < 0 || proof.legalCellCount < 0 || proof.overlapCount < 0 || proof.outsideCoreCount < 0 || proof.blockageConflictCount < 0 || proof.blockedCellCount < 0 {
                    diagnostics.append("placement proof contains negative counts")
                }
                if proof.cellCount != cells.count || proof.legalCellCount > proof.cellCount
                    || !proof.utilization.isFinite || proof.utilization < 0
                    || !proof.timingObjective.isFinite || proof.timingObjective < 0
                    || !proof.congestionObjective.isFinite || proof.congestionObjective < 0 {
                    diagnostics.append("placement proof utilization is invalid")
                }
            }
        }
        return diagnostics
    }

    private func isValid(_ rect: Rect) -> Bool {
        rect.width > 0 && rect.height > 0
            && hasValidExtent(origin: rect.x, length: rect.width)
            && hasValidExtent(origin: rect.y, length: rect.height)
    }

    private func hasValidExtent(origin: Int64, length: Int64) -> Bool {
        length > 0 && origin <= Int64.max - length
    }

    private func duplicateDiagnostics(ids: [String], kind: String) -> [String] {
        let duplicates = Dictionary(grouping: ids, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        return duplicates.map { "duplicate \(kind) identifier \($0)" }
    }
}
