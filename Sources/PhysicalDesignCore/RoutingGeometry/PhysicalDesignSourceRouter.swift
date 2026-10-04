import Foundation
import LayoutIR
import MaskGeometry

/// A finite event-grid router. Its result proves actual source geometry, not timing or production qualification.
struct PhysicalDesignSourceRouter: PhysicalDesignSourceRouting {
    struct Failure: Error, LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }
    struct Result {
        let snapshot: PhysicalDesignSnapshot
        let checks: Int
        let structuralCeiling: Int
    }
    private struct Occupancy {
        let layer: Int
        let region: Region
        let netID: String?
        let pinID: String?
        let blockage: Bool
    }
    private struct Node: Hashable {
        let x: Int
        let y: Int
        let layer: Int
    }
    private struct Step {
        let previous: Node
        let via: PhysicalDesignSnapshot.Via?
    }
    private struct Budget {
        var checks = 0
        var capacity = 0
        let caller: Int?
        mutating func admit() throws {
            try Task.checkCancellation()
            guard checks < min(capacity, caller ?? capacity) else {
                throw Failure(code: "routing_candidate_budget_exhausted", message: "The admitted routing candidate ceiling was exhausted.")
            }
            checks += 1
        }
        mutating func extend(_ value: Int) throws { capacity = try PhysicalDesignSourceRouter.add(capacity, value) }
    }

    func route(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
        mode: String, onlyNetID: String?, geometry: PhysicalDesignProcessGeometry) throws -> Result {
        try Task.checkCancellation()
        guard let core = input.core else { throw Failure(code: "core_geometry_missing", message: "Routing requires a core.") }
        let constraints = configuration.implementationConstraints ?? .default
        let width = constraints.routeWidth
        guard width > 0, width.isMultiple(of: 2) else {
            throw Failure(code: "routing_width_unsupported", message: "Source routing requires an even positive DBU default width.")
        }
        let tracks = (input.implementationState?.tracks ?? []).filter {
            configuration.preferredRoutingLayers.contains($0.layer) && $0.layer <= configuration.maximumRoutingLayer
        }
        let layers = Array(Set(tracks.map(\.layer))).sorted()
        guard !layers.isEmpty else { throw Failure(code: "routing_tracks_missing", message: "Source routing requires declared tracks.") }
        var clearances: [Int: Int64] = [:]
        for layer in layers {
            guard let number = Int16(exactly: layer), let direction = geometry.sourceLayers[number]?.direction?.rawValue.lowercased(),
                  tracks.filter({ $0.layer == layer }).allSatisfy({ $0.direction.lowercased() == direction }) else {
                throw Failure(code: "routing_tracks_invalid", message: "Retained track direction contradicts the exact source layer.")
            }
            clearances[layer] = max(constraints.routeSpacing,
                try geometry.routingWidthAndSpacing(layer: layer, units: input.unitsPerMicron, width: width).spacing)
        }
        let power = Set(configuration.powerNetNames)
        let nets = input.nets.filter { !power.contains($0.id) && (onlyNetID == nil || $0.id == onlyNetID) }.sorted { $0.id < $1.id }
        let selected = Set(nets.map(\.id))
        // FIXME(INCOMPLETE_IMPLEMENTATION): Ordinary source routing cannot update characterized CTS topology/timing records. Requests selecting CTS-owned net families must remain blocked until that owner provides exact reroute reconciliation.
        guard input.clockTrees.isEmpty else {
            throw Failure(code: "routing_clock_tree_unsupported", message: "Routing cannot reconcile an existing clock tree's topology and timing evidence.")
        }
        guard input.powerStructures.isEmpty, !input.nets.contains(where: { power.contains($0.id) }) else {
            throw Failure(code: "routing_special_nets_unsupported", message: "This source-bound routing/export profile requires normal nets without special-net structures.")
        }
        var output = input
        var occupancy: [Occupancy] = []
        let pins = Dictionary(uniqueKeysWithValues: input.pins.map { ($0.id, $0) })
        let cells = Dictionary(uniqueKeysWithValues: input.cells.map { ($0.id, $0) })
        var ports: [String: [IRBoundary]] = [:]
        var sourceCuts: [IRBoundary] = []
        for cell in input.cells {
            try Task.checkCancellation()
            let master = try geometry.requireMaster(cell.master)
            for name in master.pins.keys.sorted() {
                let shapes = try geometry.pinShapes(master: cell.master, pin: name, orientation: cell.orientation, x: cell.x, y: cell.y)
                let connected = input.pins.filter { $0.cellID == cell.id && $0.name == name }
                guard connected.count <= 1 else { throw Failure(code: "routing_pin_identity_ambiguous", message: "A source PORT has multiple canonical terminal identities.") }
                if let pin = connected.first { ports[pin.id] = shapes }
                sourceCuts.append(contentsOf: shapes.filter { geometry.sourceLayers[$0.layer]?.type == .cut })
                for (layer, values) in Dictionary(grouping: shapes, by: { Int($0.layer) }) {
                    occupancy.append(.init(layer: layer, region: Region(layer: Int16(layer), polygons: values),
                        netID: connected.first?.netID, pinID: connected.first?.id, blockage: false))
                }
            }
            for (layer, values) in Dictionary(grouping: try geometry.obstructionShapes(master: cell.master, orientation: cell.orientation, x: cell.x, y: cell.y), by: { Int($0.layer) }) {
                occupancy.append(.init(layer: layer, region: Region(layer: Int16(layer), polygons: values), netID: nil, pinID: nil, blockage: false))
            }
        }
        for rect in input.blockages {
            for layer in layers { occupancy.append(.init(layer: layer, region: try Self.rectangle(rect, layer: layer), netID: nil, pinID: nil, blockage: true)) }
        }
        for fill in input.fills { occupancy.append(.init(layer: fill.layer, region: try Self.rectangle(fill.geometry, layer: fill.layer), netID: nil, pinID: nil, blockage: false)) }
        // Validate all retained widths before deleting selected geometry: unknown facts never become request defaults.
        for route in input.routes {
            for segment in route.segments {
                guard let retainedWidth = segment.widthDBU else { throw Failure(code: "routing_retained_width_missing", message: "Retained conductor \(segment.id) has no qualified width.") }
                _ = try geometry.routingWidthAndSpacing(layer: segment.layer, units: input.unitsPerMicron, width: retainedWidth)
                let region = try Self.conductor(segment, width: retainedWidth)
                let horizontal = segment.y1 == segment.y2
                guard let source = geometry.sourceLayers[Int16(segment.layer)], source.direction?.rawValue.lowercased() == (horizontal ? "horizontal" : "vertical"),
                      Self.onTrack(x: segment.x1, y: segment.y1, layer: segment.layer, tracks: input.implementationState?.tracks ?? []),
                      Self.onTrack(x: segment.x2, y: segment.y2, layer: segment.layer, tracks: input.implementationState?.tracks ?? []),
                      try Self.fits(region, core: core) else {
                    throw Failure(code: "routing_retained_geometry_invalid", message: "Retained conductor direction, grid or full-width bounds are inconsistent with its sources.")
                }
                if !selected.contains(route.netID) {
                    let spacing = max(constraints.routeSpacing, try geometry.routingWidthAndSpacing(layer: segment.layer, units: input.unitsPerMicron, width: retainedWidth).spacing)
                    guard try Self.clear(region, layer: segment.layer, obstacles: occupancy.filter { $0.blockage || $0.netID != route.netID }, spacing: spacing) else {
                        throw Failure(code: "routing_retained_geometry_invalid", message: "Retained conductor intersects excluded source geometry or violates clearance.")
                    }
                    occupancy.append(.init(layer: segment.layer, region: region, netID: route.netID, pinID: nil, blockage: false))
                }
            }
        }
        output.routes.removeAll { selected.contains($0.netID) }
        output.vias.removeAll { selected.contains($0.netID) }
        for via in output.vias {
            guard try geometry.viaFits(via, within: core) else { throw Failure(code: "routing_retained_geometry_invalid", message: "A retained fixed contact leaves the core.") }
            guard let name = via.master else { throw Failure(code: "routing_via_source_invalid", message: "Retained fixed contact has no exact source master.") }
            for shape in try geometry.viaShapes(master: name, x: via.x, y: via.y) {
                let sourceClearance = geometry.sourceLayers[shape.layer]?.type == .cut
                    ? Int64(geometry.cutSpacings[shape.layer] ?? 0)
                    : max(constraints.routeSpacing, try geometry.routingWidthAndSpacing(layer: Int(shape.layer), units: input.unitsPerMicron, width: width).spacing)
                guard try Self.clear(Region(layer: shape.layer, polygons: [shape]), layer: Int(shape.layer), obstacles: occupancy.filter { $0.blockage || $0.netID != via.netID }, spacing: sourceClearance) else {
                    throw Failure(code: "routing_retained_geometry_invalid", message: "Retained fixed contact intersects excluded source geometry or violates clearance.")
                }
            }
            try Self.appendMetal(via, geometry: geometry, to: &occupancy)
        }
        try geometry.validateRoutingCuts(output.vias, sourceCuts: sourceCuts)
        var budget = Budget(caller: configuration.maximumRoutingCandidateChecks)
        for net in nets {
            try Task.checkCancellation()
            let terminals = try net.pinIDs.sorted().map { id -> PhysicalDesignSnapshot.Pin in
                guard let pin = pins[id], pin.netID == net.id, let cellID = pin.cellID, cells[cellID] != nil,
                      let layer = pin.accessLayer, layers.contains(layer), ports[id] != nil else {
                    throw Failure(code: "routing_pin_source_invalid", message: "Net \(net.id) requires exact component PORTs, explicit layers and matching terminal identities.")
                }
                return pin
            }
            guard terminals.count >= 2 else { throw Failure(code: "routing_connectivity_missing", message: "Each selected net requires at least two source terminals.") }
            let relevant = occupancy.filter { $0.blockage || $0.netID != net.id }
            let events = try Self.events(core: core, terminals: terminals, ports: ports, occupancy: relevant,
                geometry: geometry, tracks: tracks, width: width, clearance: clearances.values.max() ?? 0)
            let xs = events.x, ys = events.y
            let xy = try Self.multiply(xs.count, ys.count)
            let accessBound = try Self.multiply(terminals.count, xy)
            let states = try Self.multiply(layers.count, xy)
            let searchBound = try Self.multiply(try Self.multiply(terminals.count - 1, states), try Self.add(layers.count, 3))
            try budget.extend(try Self.add(accessBound, searchBound))
            func point(_ node: Node) -> (Int64, Int64) { (xs[node.x], ys[node.y]) }
            func onTrack(_ node: Node) -> Bool {
                Self.onTrack(x: xs[node.x], y: ys[node.y], layer: node.layer, tracks: tracks)
            }
            func clear(_ region: Region, layer: Int) throws -> Bool {
                try Self.clear(region, layer: layer, obstacles: relevant, spacing: clearances[layer] ?? 0)
            }
            var accesses: [[Node]] = []
            for terminal in terminals {
                let layer = terminal.accessLayer!
                let port = Region(layer: Int16(layer), polygons: ports[terminal.id, default: []].filter { Int($0.layer) == layer })
                var candidates: [Node] = []
                for x in xs.indices {
                    for y in ys.indices {
                        try budget.admit()
                        let node = Node(x: x, y: y, layer: layer)
                        guard onTrack(node) else { continue }
                        let cap = try Self.cap(x: xs[x], y: ys[y], width: width, layer: layer)
                        if try cap.subtracting(port).isEmpty && clear(cap, layer: layer) { candidates.append(node) }
                    }
                }
                guard !candidates.isEmpty else { throw Failure(code: "routing_pin_access_unavailable", message: "Terminal \(terminal.id) has no full-width track access contained in its source PORT.") }
                accesses.append(candidates)
            }
            var segments: [PhysicalDesignSnapshot.RouteSegment] = []
            var contacts: [PhysicalDesignSnapshot.Via] = []
            var root: Node?
            for targetOrdinal in 1..<terminals.count {
                let starts = root.map { [$0] } ?? accesses[0]
                let targets = Set(accesses[targetOrdinal])
                var queue = starts
                var cursor = 0
                var visited = Set(starts)
                var previous: [Node: Step] = [:]
                var found: Node?
                while cursor < queue.count {
                    try Task.checkCancellation()
                    let node = queue[cursor]; cursor += 1
                    if targets.contains(node) && previous[node] != nil { found = node; break }
                    var neighbors: [Node] = []
                    let horizontal = tracks.contains { $0.layer == node.layer && $0.direction.lowercased() == "horizontal" }
                    if horizontal {
                        if node.x > 0 { neighbors.append(.init(x: node.x - 1, y: node.y, layer: node.layer)) }
                        if node.x + 1 < xs.count { neighbors.append(.init(x: node.x + 1, y: node.y, layer: node.layer)) }
                    } else {
                        if node.y > 0 { neighbors.append(.init(x: node.x, y: node.y - 1, layer: node.layer)) }
                        if node.y + 1 < ys.count { neighbors.append(.init(x: node.x, y: node.y + 1, layer: node.layer)) }
                    }
                    neighbors.append(contentsOf: layers.filter { $0 != node.layer }.map { .init(x: node.x, y: node.y, layer: $0) })
                    for next in neighbors where !visited.contains(next) && onTrack(next) {
                        try budget.admit()
                        let a = point(node), b = point(next)
                        var via: PhysicalDesignSnapshot.Via?
                        if node.layer == next.layer {
                            let segment = PhysicalDesignSnapshot.RouteSegment(id: "candidate", layer: node.layer, x1: a.0, y1: a.1, x2: b.0, y2: b.1, widthDBU: width)
                            let conductor = try Self.conductor(segment, width: width)
                            guard try Self.fits(conductor, core: core), try clear(conductor, layer: node.layer) else { continue }
                        } else {
                            let defaults = geometry.vias.values.filter { $0.definition.isDefault && Int($0.lowerLayer) == min(node.layer, next.layer) && Int($0.upperLayer) == max(node.layer, next.layer) }
                            guard defaults.count == 1 else { continue }
                            let candidate = PhysicalDesignSnapshot.Via(id: "candidate", netID: net.id, x: a.0, y: a.1, lowerLayer: min(node.layer, next.layer), upperLayer: max(node.layer, next.layer), master: defaults[0].definition.name)
                            guard try geometry.viaFits(candidate, within: core) else { continue }
                            let shapes = try geometry.viaShapes(master: defaults[0].definition.name, x: a.0, y: a.1)
                            var usable = true
                            for layer in [node.layer, next.layer] {
                                let metal = Region(layer: Int16(layer), polygons: shapes.filter { Int($0.layer) == layer })
                                let cap = try Self.cap(x: a.0, y: a.1, width: width, layer: layer)
                                if try metal.intersection(cap).isEmpty || !clear(metal, layer: layer) { usable = false; break }
                            }
                            for shape in shapes where geometry.sourceLayers[shape.layer]?.type == .cut {
                                let cut = Region(layer: shape.layer, polygons: [shape])
                                if try !Self.clear(cut, layer: Int(shape.layer), obstacles: relevant, spacing: Int64(geometry.cutSpacings[shape.layer] ?? 0)) { usable = false; break }
                            }
                            guard usable, try geometry.routingCutsFit(candidate, against: output.vias, sourceCuts: sourceCuts) else { continue }
                            via = candidate
                        }
                        visited.insert(next)
                        previous[next] = .init(previous: node, via: via)
                        queue.append(next)
                    }
                }
                guard var end = found else { throw Failure(code: "routing_path_unavailable", message: "No legal conductor/contact path exists in the admitted boundary-event domain for net \(net.id).") }
                let targetPoint = point(end)
                if let pinIndex = output.pins.firstIndex(where: { $0.id == terminals[targetOrdinal].id }) {
                    output.pins[pinIndex].x = targetPoint.0; output.pins[pinIndex].y = targetPoint.1
                }
                while let step = previous[end] {
                    let a = point(step.previous), b = point(end)
                    if var via = step.via {
                        if !contacts.contains(where: { $0.x == via.x && $0.y == via.y && $0.master == via.master }) {
                            via.id = "route_\(net.id)_via_\(contacts.count)"; contacts.append(via)
                        }
                    } else {
                        segments.append(.init(id: "route_\(net.id)_segment_\(segments.count)", layer: end.layer,
                            x1: a.0, y1: a.1, x2: b.0, y2: b.1, widthDBU: width))
                    }
                    end = step.previous
                }
                root = end
            }
            guard !segments.isEmpty, let root else { throw Failure(code: "routing_connectivity_missing", message: "Collocated terminals cannot be represented by a nonempty routed conductor.") }
            let rootPoint = point(root)
            if let pinIndex = output.pins.firstIndex(where: { $0.id == terminals[0].id }) { output.pins[pinIndex].x = rootPoint.0; output.pins[pinIndex].y = rootPoint.1 }
            // Validate all path contacts before publishing any net geometry; no center-distance proxy.
            try geometry.validateRoutingCuts(output.vias + contacts, sourceCuts: sourceCuts)
            for segment in segments { occupancy.append(.init(layer: segment.layer, region: try Self.conductor(segment, width: width), netID: net.id, pinID: nil, blockage: false)) }
            for via in contacts { try Self.appendMetal(via, geometry: geometry, to: &occupancy) }
            output.vias.append(contentsOf: contacts)
            output.routes.append(.init(id: "route_\(net.id)", netID: net.id, segments: segments))
        }
        try geometry.validate(output)
        var state = output.implementationState ?? .init()
        state.routingEvidence = .init(mode: mode, routedNetCount: nets.count, skippedNetIDs: [], viaCount: output.vias.count)
        output.implementationState = state
        output.metadata["routingStatus"] = mode
        return .init(snapshot: output, checks: budget.checks, structuralCeiling: budget.capacity)
    }

    static func conductor(_ segment: PhysicalDesignSnapshot.RouteSegment, width: Int64) throws -> Region {
        guard width > 0, width.isMultiple(of: 2), (segment.x1 == segment.x2) != (segment.y1 == segment.y2) else {
            throw Failure(code: "routing_width_unsupported", message: "A conductor requires nonzero orthogonal geometry and an even positive width.")
        }
        return try box(minX: subtract(min(segment.x1, segment.x2), width / 2), minY: subtract(min(segment.y1, segment.y2), width / 2),
            maxX: add(max(segment.x1, segment.x2), width / 2), maxY: add(max(segment.y1, segment.y2), width / 2), layer: segment.layer)
    }
    static func cap(x: Int64, y: Int64, width: Int64, layer: Int) throws -> Region {
        try box(minX: subtract(x, width / 2), minY: subtract(y, width / 2), maxX: add(x, width / 2), maxY: add(y, width / 2), layer: layer)
    }
    private static func rectangle(_ rect: PhysicalDesignSnapshot.Rect, layer: Int) throws -> Region {
        try box(minX: rect.x, minY: rect.y, maxX: add(rect.x, rect.width), maxY: add(rect.y, rect.height), layer: layer)
    }
    private static func box(minX: Int64, minY: Int64, maxX: Int64, maxY: Int64, layer: Int) throws -> Region {
        guard let a = Int32(exactly: minX), let b = Int32(exactly: minY), let c = Int32(exactly: maxX), let d = Int32(exactly: maxY),
              a < c, b < d, let native = Int16(exactly: layer) else { throw Failure(code: "routing_coordinate_overflow", message: "Conductor geometry exceeds the exact integer backend.") }
        return Region(layer: native, polygons: [.init(layer: native, datatype: 0, points: [.init(x: a, y: b), .init(x: c, y: b), .init(x: c, y: d), .init(x: a, y: d), .init(x: a, y: b)])])
    }
    private static func fits(_ region: Region, core: PhysicalDesignSnapshot.Rect) throws -> Bool {
        guard let box = region.boundingBox else { return false }
        return core.containsPoint(x: Int64(box.minX), y: Int64(box.minY)) && core.containsPoint(x: Int64(box.maxX), y: Int64(box.maxY))
    }
    private static func clear(_ region: Region, layer: Int, obstacles: [Occupancy], spacing: Int64) throws -> Bool {
        guard let minimum = Int32(exactly: spacing) else { throw Failure(code: "routing_coordinate_overflow", message: "Spacing exceeds the integer backend.") }
        for obstacle in obstacles where obstacle.layer == layer {
            if try !region.intersection(obstacle.region).isEmpty { return false }
            if try !obstacle.blockage && minimum > 0 && !region.spaceViolations(to: obstacle.region, minSpace: minimum).isEmpty { return false }
        }
        return true
    }
    private static func appendMetal(_ via: PhysicalDesignSnapshot.Via, geometry: PhysicalDesignProcessGeometry, to occupancy: inout [Occupancy]) throws {
        guard let master = via.master else { throw Failure(code: "routing_via_source_invalid", message: "Retained via has no exact master.") }
        let shapes = try geometry.viaShapes(master: master, x: via.x, y: via.y)
        for layer in [via.lowerLayer, via.upperLayer] {
            occupancy.append(.init(layer: layer, region: Region(layer: Int16(layer), polygons: shapes.filter { Int($0.layer) == layer }), netID: via.netID, pinID: nil, blockage: false))
        }
    }
    private static func onTrack(x: Int64, y: Int64, layer: Int, tracks: [PhysicalDesignImplementationState.Track]) -> Bool {
        tracks.contains { track in
            guard track.layer == layer, track.spacing > 0, track.count > 0 else { return false }
            let coordinate = track.direction.lowercased() == "horizontal" ? y : x
            let (offset, overflow) = coordinate.subtractingReportingOverflow(track.origin)
            return !overflow && offset >= 0 && offset % track.spacing == 0 && offset / track.spacing < track.count
        }
    }
    private static func events(core: PhysicalDesignSnapshot.Rect, terminals: [PhysicalDesignSnapshot.Pin], ports: [String: [IRBoundary]],
        occupancy: [Occupancy], geometry: PhysicalDesignProcessGeometry, tracks: [PhysicalDesignImplementationState.Track], width: Int64, clearance: Int64) throws -> (x: [Int64], y: [Int64]) {
        let half = width / 2
        let xMin = try add(core.x, half), xMax = try subtract(add(core.x, core.width), half)
        let yMin = try add(core.y, half), yMax = try subtract(add(core.y, core.height), half)
        guard xMin <= xMax, yMin <= yMax else { throw Failure(code: "routing_core_boundary_conflict", message: "The core cannot contain a full-width conductor.") }
        var x: Set<Int64> = [xMin, xMax], y: Set<Int64> = [yMin, yMax]
        var extent = half
        for via in geometry.vias.values where via.definition.isDefault {
            for shape in via.shapes { for p in shape.points { extent = max(extent, abs(Int64(p.x)), abs(Int64(p.y))) } }
        }
        let outer = try add(extent, clearance)
        let offsets: Set<Int64> = [0, half, -half, outer, -outer]
        func insert(_ points: [IRPoint]) throws {
            for point in points {
                try Task.checkCancellation()
                for offset in offsets { x.insert(try add(Int64(point.x), offset)); y.insert(try add(Int64(point.y), offset)) }
            }
        }
        for terminal in terminals { for shape in ports[terminal.id, default: []] { try insert(shape.points) } }
        for item in occupancy { for polygon in item.region.polygons { try insert(polygon.points) } }
        // Only floor/ceil tracks adjacent to geometry events are added; declared track count is never enumerated.
        let baseX = x, baseY = y
        for track in tracks {
            guard track.spacing > 0, track.count > 0 else { throw Failure(code: "routing_tracks_invalid", message: "Tracks require positive pitch and count.") }
            let horizontal = track.direction.lowercased() == "horizontal"
            for coordinate in horizontal ? baseY : baseX {
                let delta = try subtract(coordinate, track.origin)
                var ordinal = delta / track.spacing
                if delta < 0 && delta % track.spacing != 0 { ordinal = try subtract(ordinal, 1) }
                for index in [ordinal, try add(ordinal, 1)] where index >= 0 && index < track.count {
                    let value = try add(track.origin, multiply(index, track.spacing))
                    if horizontal { y.insert(value) } else { x.insert(value) }
                }
            }
        }
        return (x.filter { $0 >= xMin && $0 <= xMax }.sorted(), y.filter { $0 >= yMin && $0 <= yMax }.sorted())
    }
    private static func add<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw Failure(code: "routing_coordinate_overflow", message: "Routing arithmetic overflowed.") }; return value
    }
    private static func subtract<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        guard !overflow else { throw Failure(code: "routing_coordinate_overflow", message: "Routing arithmetic overflowed.") }; return value
    }
    private static func multiply<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw Failure(code: "routing_coordinate_overflow", message: "Routing capacity arithmetic overflowed.") }; return value
    }
}
