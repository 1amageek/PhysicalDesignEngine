import Foundation

public struct PhysicalDesignImplementationState: Sendable, Hashable, Codable {
    public struct Track: Sendable, Hashable, Codable {
        public var id: String
        public var layer: Int
        public var direction: String
        public var origin: Int64
        public var spacing: Int64
        public var count: Int64

        public init(id: String, layer: Int, direction: String, origin: Int64, spacing: Int64, count: Int64) {
            self.id = id
            self.layer = layer
            self.direction = direction
            self.origin = origin
            self.spacing = spacing
            self.count = count
        }
    }

    public struct PowerDomain: Sendable, Hashable, Codable {
        public var id: String
        public var netIDs: [String]
        public var geometry: PhysicalDesignSnapshot.Rect
        public var voltageMillivolts: Int64?

        public init(id: String, netIDs: [String], geometry: PhysicalDesignSnapshot.Rect, voltageMillivolts: Int64? = nil) {
            self.id = id
            self.netIDs = netIDs
            self.geometry = geometry
            self.voltageMillivolts = voltageMillivolts
        }
    }

    public struct Pad: Sendable, Hashable, Codable {
        public var id: String
        public var pinID: String
        public var side: String
        public var geometry: PhysicalDesignSnapshot.Rect
        public var placed: Bool

        public init(id: String, pinID: String, side: String, geometry: PhysicalDesignSnapshot.Rect, placed: Bool = false) {
            self.id = id
            self.pinID = pinID
            self.side = side
            self.geometry = geometry
            self.placed = placed
        }
    }

    public struct PlacementProof: Sendable, Hashable, Codable {
        public var cellCount: Int
        public var legalCellCount: Int
        public var overlapCount: Int
        public var outsideCoreCount: Int
        public var blockageConflictCount: Int
        public var blockedCellCount: Int
        public var utilization: Double
        public var timingObjective: Double
        public var congestionObjective: Double

        public init(
            cellCount: Int,
            legalCellCount: Int,
            overlapCount: Int,
            outsideCoreCount: Int,
            blockageConflictCount: Int,
            blockedCellCount: Int,
            utilization: Double,
            timingObjective: Double,
            congestionObjective: Double
        ) {
            self.cellCount = cellCount
            self.legalCellCount = legalCellCount
            self.overlapCount = overlapCount
            self.outsideCoreCount = outsideCoreCount
            self.blockageConflictCount = blockageConflictCount
            self.blockedCellCount = blockedCellCount
            self.utilization = utilization
            self.timingObjective = timingObjective
            self.congestionObjective = congestionObjective
        }
    }

    public struct ClockRouteConstraint: Sendable, Hashable, Codable {
        public var id: String
        public var netID: String
        public var layer: Int
        public var width: Int64
        public var spacing: Int64
        public var maximumLength: Int64?

        public init(id: String, netID: String, layer: Int, width: Int64, spacing: Int64, maximumLength: Int64? = nil) {
            self.id = id
            self.netID = netID
            self.layer = layer
            self.width = width
            self.spacing = spacing
            self.maximumLength = maximumLength
        }
    }

    public struct RoutingEvidence: Sendable, Hashable, Codable {
        public var mode: String
        public var routedNetCount: Int
        public var skippedNetIDs: [String]
        public var blockageConflictCount: Int
        public var layerDirectionViolations: Int
        public var spacingConflicts: Int
        public var antennaRiskNetIDs: [String]
        public var viaCount: Int

        public init(
            mode: String,
            routedNetCount: Int,
            skippedNetIDs: [String] = [],
            blockageConflictCount: Int = 0,
            layerDirectionViolations: Int = 0,
            spacingConflicts: Int = 0,
            antennaRiskNetIDs: [String] = [],
            viaCount: Int = 0
        ) {
            self.mode = mode
            self.routedNetCount = routedNetCount
            self.skippedNetIDs = skippedNetIDs
            self.blockageConflictCount = blockageConflictCount
            self.layerDirectionViolations = layerDirectionViolations
            self.spacingConflicts = spacingConflicts
            self.antennaRiskNetIDs = antennaRiskNetIDs
            self.viaCount = viaCount
        }
    }

    public struct RepairProof: Sendable, Hashable, Codable {
        public var stage: String
        public var strategy: String
        public var targetIDs: [String]
        public var violationsBefore: Int
        public var violationsAfter: Int
        public var verified: Bool
        public var details: [String]

        public init(
            stage: String,
            strategy: String,
            targetIDs: [String],
            violationsBefore: Int,
            violationsAfter: Int,
            verified: Bool,
            details: [String] = []
        ) {
            self.stage = stage
            self.strategy = strategy
            self.targetIDs = targetIDs
            self.violationsBefore = violationsBefore
            self.violationsAfter = violationsAfter
            self.verified = verified
            self.details = details
        }
    }

    public var tracks: [Track]
    public var powerDomains: [PowerDomain]
    public var pads: [Pad]
    public var placementProof: PlacementProof?
    public var clockRouteConstraints: [ClockRouteConstraint]
    public var routingEvidence: RoutingEvidence?
    public var repairProofs: [RepairProof]

    private enum CodingKeys: String, CodingKey {
        case tracks
        case powerDomains
        case pads
        case placementProof
        case clockRouteConstraints
        case routingEvidence
        case repairProofs
    }

    public init(
        tracks: [Track] = [],
        powerDomains: [PowerDomain] = [],
        pads: [Pad] = [],
        placementProof: PlacementProof? = nil,
        clockRouteConstraints: [ClockRouteConstraint] = [],
        routingEvidence: RoutingEvidence? = nil,
        repairProofs: [RepairProof] = []
    ) {
        self.tracks = tracks
        self.powerDomains = powerDomains
        self.pads = pads
        self.placementProof = placementProof
        self.clockRouteConstraints = clockRouteConstraints
        self.routingEvidence = routingEvidence
        self.repairProofs = repairProofs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        powerDomains = try container.decodeIfPresent([PowerDomain].self, forKey: .powerDomains) ?? []
        pads = try container.decodeIfPresent([Pad].self, forKey: .pads) ?? []
        placementProof = try container.decodeIfPresent(PlacementProof.self, forKey: .placementProof)
        clockRouteConstraints = try container.decodeIfPresent([ClockRouteConstraint].self, forKey: .clockRouteConstraints) ?? []
        routingEvidence = try container.decodeIfPresent(RoutingEvidence.self, forKey: .routingEvidence)
        repairProofs = try container.decodeIfPresent([RepairProof].self, forKey: .repairProofs) ?? []
    }
}
