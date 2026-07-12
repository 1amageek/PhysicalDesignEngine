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

        public var maxX: Int64 { x + width }
        public var maxY: Int64 { y + height }

        public func contains(_ other: Rect) -> Bool {
            other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
        }

        public func containsPoint(x pointX: Int64, y pointY: Int64) -> Bool {
            pointX >= x && pointX <= maxX && pointY >= y && pointY <= maxY
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
        metadata: [String: String] = [:]
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
        let cellIDs = Set(cells.map(\.id))
        for pin in pins {
            if let cellID = pin.cellID, !cellIDs.contains(cellID) {
                diagnostics.append("pin \(pin.id) refers to missing cell \(cellID)")
            }
        }
        let pinIDs = Set(pins.map(\.id))
        for net in nets {
            let missingPins = net.pinIDs.filter { !pinIDs.contains($0) }
            if !missingPins.isEmpty {
                diagnostics.append("net \(net.id) refers to missing pins \(missingPins.sorted().joined(separator: ","))")
            }
        }
        return diagnostics
    }

    private func isValid(_ rect: Rect) -> Bool {
        rect.width > 0 && rect.height > 0
    }

    private func duplicateDiagnostics(ids: [String], kind: String) -> [String] {
        let duplicates = Dictionary(grouping: ids, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        return duplicates.map { "duplicate \(kind) identifier \($0)" }
    }
}
