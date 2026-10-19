import LayoutIR
import MaskGeometry

/// Owns actual fill exclusion surfaces and caller-bounded geometry probes.
struct PhysicalDesignFillAdmission {
    private struct Obstacle { let layer: Int; let region: Region }
    private let obstacles: [Obstacle]
    private let core: PhysicalDesignSnapshot.Rect
    private let spacing: Int32
    private let units: Int
    private let processGeometry: PhysicalDesignProcessGeometry?
    private let window: Int64
    private let maximumDensity: Double
    private let maximumChecks: Int?
    private(set) var checks = 0

    init(snapshot: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
         geometry: PhysicalDesignProcessGeometry?) throws {
        guard let core = snapshot.core else { throw PhysicalDesignTechnologyError.invalid("Fill requires a core.") }
        let repair = configuration.repairConstraints ?? .default
        self.processGeometry = geometry; units = snapshot.unitsPerMicron
        self.core = core; window = configuration.fillWindowSize; maximumDensity = repair.maximumFillDensity
        maximumChecks = repair.maximumGeometryChecks
        let layer = configuration.preferredRoutingLayers[0]
        let clearance = max(configuration.fillSpacing, repair.minimumFillSpacing)
        guard let spacing = Int32(exactly: clearance) else { throw PhysicalDesignTechnologyError.invalid("Fill spacing exceeds the geometry backend.") }
        self.spacing = spacing
        var obstacles: [Obstacle] = []
        for cell in snapshot.cells where cell.placed {
            try Task.checkCancellation()
            if let geometry {
                var shapes = try geometry.obstructionShapes(master: cell.master, orientation: cell.orientation, x: cell.x, y: cell.y)
                for name in try geometry.requireMaster(cell.master).pins.keys.sorted() {
                    shapes += try geometry.pinShapes(master: cell.master, pin: name, orientation: cell.orientation, x: cell.x, y: cell.y)
                }
                for shape in shapes { obstacles.append(.init(layer: Int(shape.layer), region: Region(layer: shape.layer, polygons: [shape]))) }
            }
            obstacles.append(.init(layer: layer, region: try PhysicalDesignSourceRouter.rectangle(.init(x: cell.x, y: cell.y, width: cell.width, height: cell.height), layer: layer)))
        }
        for pin in snapshot.pins where pin.cellID == nil {
            if let port = pin.topPort { obstacles.append(.init(layer: port.layer, region: try PhysicalDesignSourceRouter.rectangle(port.worldRectangle(), layer: port.layer))) }
        }
        for route in snapshot.routes {
            for segment in route.segments {
                var qualified = segment
                if qualified.widthDBU == nil || qualified.endpointExtensions == nil {
                    guard geometry == nil else { throw PhysicalDesignTechnologyError.unsupported("Fill requires retained qualified source conductor geometry.") }
                    // FIXME(INCOMPLETE_IMPLEMENTATION): Source-free smoke has request-width square caps only.
                    // It cannot qualify the actual process conductor footprint used by source-bound fill.
                    let width = configuration.implementationConstraints?.routeWidth ?? PhysicalDesignImplementationConstraints.default.routeWidth
                    qualified.widthDBU = width; qualified.endpointExtensions = .init(beginDBU: width / 2, endDBU: width / 2)
                }
                obstacles.append(.init(layer: segment.layer, region: try PhysicalDesignSourceRouter.rectangle(qualified.qualifiedFootprint(), layer: segment.layer)))
            }
        }
        for via in snapshot.vias {
            if let geometry, let master = via.master {
                for shape in try geometry.viaShapes(master: master, x: via.x, y: via.y) {
                    obstacles.append(.init(layer: Int(shape.layer), region: Region(layer: shape.layer, polygons: [shape])))
                }
            } else if geometry != nil { throw PhysicalDesignTechnologyError.unsupported("Fill requires exact fixed contact geometry.") }
        }
        for structure in snapshot.powerStructures { obstacles.append(.init(layer: structure.layer, region: try PhysicalDesignSourceRouter.rectangle(structure.geometry, layer: structure.layer))) }
        for rect in snapshot.blockages { obstacles.append(.init(layer: layer, region: try PhysicalDesignSourceRouter.rectangle(rect, layer: layer))) }
        self.obstacles = obstacles
    }

    private mutating func charge() throws {
        try Task.checkCancellation()
        let next = checks.addingReportingOverflow(1)
        guard !next.overflow, maximumChecks == nil || next.partialValue <= maximumChecks! else {
            throw PhysicalDesignTechnologyError.invalid("Fill geometry check ceiling exhausted.")
        }
        checks = next.partialValue
    }

    mutating func accepts(_ fill: PhysicalDesignSnapshot.Fill, existing: [PhysicalDesignSnapshot.Fill]) throws -> Bool {
        try charge()
        guard core.contains(fill.geometry) else { return false }
        var spacing = self.spacing
        if let geometry = processGeometry {
            guard let layer = Int16(exactly: fill.layer), let source = geometry.sourceLayers[layer], source.type == .routing,
                  let declared = source.spacing else { throw PhysicalDesignTechnologyError.unsupported("Fill clearance requires its layer's exact source SPACING.") }
            let value = try PhysicalDesignProcessInputs.dbu(declared, units: units, field: "fill SPACING")
            guard let exact = Int32(exactly: value) else { throw PhysicalDesignTechnologyError.invalid("Fill source spacing exceeds the geometry backend.") }
            spacing = max(spacing, exact)
        }
        let region = try PhysicalDesignSourceRouter.rectangle(fill.geometry, layer: fill.layer)
        for obstacle in obstacles where obstacle.layer == fill.layer {
            try charge()
            if try !region.intersection(obstacle.region).isEmpty { return false }
            if spacing > 0, try !region.spaceViolations(to: obstacle.region, minSpace: spacing).isEmpty { return false }
        }
        for other in existing where other.layer == fill.layer {
            try charge()
            let otherRegion = try PhysicalDesignSourceRouter.rectangle(other.geometry, layer: other.layer)
            if try !region.intersection(otherRegion).isEmpty { return false }
            if spacing > 0, try !region.spaceViolations(to: otherRegion, minSpace: spacing).isEmpty { return false }
        }
        // Examine only windows touched by this candidate, using the declared core-origin lattice.
        let beginX = (fill.geometry.x - core.x) / window, endX = (fill.geometry.maxX - 1 - core.x) / window
        let beginY = (fill.geometry.y - core.y) / window, endY = (fill.geometry.maxY - 1 - core.y) / window
        for iy in beginY...endY {
            for ix in beginX...endX {
                try charge()
                let x = core.x + ix * window, y = core.y + iy * window
                let rect = PhysicalDesignSnapshot.Rect(x: x, y: y, width: min(window, core.maxX - x), height: min(window, core.maxY - y))
                var area = intersectionArea(fill.geometry, rect)
                for other in existing where other.layer == fill.layer { try charge(); area += intersectionArea(other.geometry, rect) }
                if area > Double(rect.width) * Double(rect.height) * maximumDensity { return false }
            }
        }
        return true
    }

    private func intersectionArea(_ a: PhysicalDesignSnapshot.Rect, _ b: PhysicalDesignSnapshot.Rect) -> Double {
        Double(max(0, min(a.maxX, b.maxX) - max(a.x, b.x))) * Double(max(0, min(a.maxY, b.maxY) - max(a.y, b.y)))
    }
}
