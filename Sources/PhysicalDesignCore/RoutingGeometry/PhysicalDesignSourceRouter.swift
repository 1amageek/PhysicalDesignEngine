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
        let blockage: Bool
        let spacingWidthOverride: Int64?
        let spacingObject: PhysicalDesignRoutingSpacingObject?
    }
    private typealias Node = PhysicalDesignRoutingSearch.Node
    private struct Access {
        let node: Node
        let contact: Int?
    }

    func route(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
        mode: String, onlyNetID: String?, geometry: PhysicalDesignProcessGeometry) throws -> Result {
        try route(input, configuration: configuration, mode: mode, onlyNetID: onlyNetID, geometry: geometry, bypassingLayers: [])
    }

    func route(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
        mode: String, onlyNetID: String?, geometry: PhysicalDesignProcessGeometry, bypassingLayers: Set<Int>,
        terminalTrackJogs: Bool = true) throws -> Result {
        try Task.checkCancellation()
        guard let core = input.core else { throw Failure(code: "core_geometry_missing", message: "Routing requires a core.") }
        let constraints = configuration.implementationConstraints ?? .default
        let requestedWidth: Int64? = constraints.sourceRoutingWidthPolicy == .sourceDefault ? nil : constraints.routeWidth
        guard requestedWidth == nil || (constraints.routeWidth > 0 && constraints.routeWidth.isMultiple(of: 2)) else {
            throw Failure(code: "routing_width_unsupported", message: "Source routing requires an even positive DBU default width.")
        }
        let tracks = (input.implementationState?.tracks ?? []).filter {
            configuration.preferredRoutingLayers.contains($0.layer) && $0.layer <= configuration.maximumRoutingLayer
        }
        let layers = Self.blockageLayers(input, configuration: configuration).sorted()
        guard !layers.isEmpty else { throw Failure(code: "routing_tracks_missing", message: "Source routing requires declared tracks.") }
        for layer in layers {
            guard let number = Int16(exactly: layer), let direction = geometry.sourceLayers[number]?.direction?.rawValue.lowercased(),
                  tracks.filter({ $0.layer == layer }).allSatisfy({ $0.direction.lowercased() == direction }) else {
                throw Failure(code: "routing_tracks_invalid", message: "Retained track direction contradicts the exact source layer.")
            }
        }
        let power = Set(configuration.powerNetNames)
        let clockBufferIDs = Set(input.clockTrees.flatMap(\.bufferCellIDs))
        let clockNets = Set(input.clockTrees.map(\.netID)).union(input.pins.compactMap {
            $0.cellID.map { clockBufferIDs.contains($0) } == true ? $0.netID : nil
        }).union(input.clockTrees.flatMap(\.sinkPinIDs).compactMap { id in input.pins.first { $0.id == id }?.netID })
        // FIXME(INCOMPLETE_IMPLEMENTATION): CTS-owned family rerouting requires retained-tree
        // recharacterization. Ordinary routing preserves these exact families instead of selecting them.
        if let onlyNetID, clockNets.contains(onlyNetID) {
            throw Failure(code: "routing_clock_tree_unsupported", message: "CTS owns rerouting and recharacterization of its retained net families.")
        }
        let nets = input.nets.filter {
            !clockNets.contains($0.id) && ($0.routingClass == .special || !power.contains($0.id)) && (onlyNetID == nil || $0.id == onlyNetID)
        }.sorted { $0.id < $1.id }
        let selected = Set(nets.map(\.id))
        try Self.validateSpecialNetMutation(input, selectedNetIDs: selected, configuration: configuration, geometry: geometry)
        guard input.powerStructures.isEmpty, !input.nets.contains(where: { power.contains($0.id) && $0.routingClass != .special }) else {
            throw Failure(code: "routing_special_nets_unsupported", message: "Finite routing cannot synthesize power structures or reconcile regular power-grid ownership.")
        }
        var budget = PhysicalDesignRoutingWorkBudget(caller: configuration.maximumRoutingCandidateChecks)
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
                    occupancy.append(try Self.occupied(layer: layer, region: Region(layer: Int16(layer), polygons: values),
                        netID: connected.first?.netID, geometry: geometry, budget: &budget))
                }
            }
            for (layer, values) in Dictionary(grouping: try geometry.obstructionShapes(master: cell.master, orientation: cell.orientation, x: cell.x, y: cell.y), by: { Int($0.layer) }) {
                occupancy.append(try Self.occupied(layer: layer, region: Region(layer: Int16(layer), polygons: values), netID: nil, obstruction: true, geometry: geometry, budget: &budget))
            }
        }
        for pin in input.pins where pin.cellID == nil {
            guard let port = pin.topPort, pin.accessLayer == port.layer, pin.netID != nil else {
                throw Failure(code: "routing_pin_source_invalid", message: "Top terminal \(pin.id) requires exact source RECT, layer and net identity.")
            }
            let surface = try Self.rectangle(port.worldRectangle(), layer: port.layer)
            ports[pin.id] = surface.polygons
            occupancy.append(try Self.occupied(layer: port.layer, region: surface, netID: pin.netID, geometry: geometry, budget: &budget))
        }
        for rect in input.blockages {
            for layer in layers { occupancy.append(try Self.occupied(layer: layer, region: Self.rectangle(rect, layer: layer), netID: nil, blockage: true, geometry: geometry, budget: &budget)) }
        }
        for fill in input.fills { occupancy.append(try Self.occupied(layer: fill.layer, region: Self.rectangle(fill.geometry, layer: fill.layer), netID: nil, geometry: geometry, budget: &budget)) }
        // Validate all retained widths before deleting selected geometry: unknown facts never become request defaults.
        for route in input.routes {
            guard let owner = input.nets.first(where: { $0.id == route.netID }), let routeClass = owner.routingClass,
                  let status = route.defStatus, [.routed, .fixed, .cover].contains(status),
                  routeClass == .special || route.defShape == nil else {
                throw Failure(code: "routing_retained_profile_invalid", message: "Retained route requires exact net container, status and supported shape semantics.")
            }
            for segment in route.segments {
                guard let retainedWidth = segment.widthDBU else { throw Failure(code: "routing_retained_width_missing", message: "Retained conductor \(segment.id) has no qualified width.") }
                _ = try geometry.routingWidthAndSpacing(layer: segment.layer, units: input.unitsPerMicron, width: retainedWidth, explicitSpecialWidth: routeClass == .special, areaHandledSeparately: true)
                let region = try Self.conductor(segment, width: retainedWidth)
                guard geometry.sourceLayers[Int16(segment.layer)]?.direction != nil,
                      Self.onTrack(x: segment.x1, y: segment.y1, layer: segment.layer, tracks: input.implementationState?.tracks ?? []),
                      Self.onTrack(x: segment.x2, y: segment.y2, layer: segment.layer, tracks: input.implementationState?.tracks ?? []),
                      try Self.fits(region, core: core) else {
                    throw Failure(code: "routing_retained_geometry_invalid", message: "Retained conductor direction, grid or full-width bounds are inconsistent with its sources.")
                }
                if !selected.contains(route.netID) {
                    let spacing = max(constraints.routeSpacing, try geometry.routingWidthAndSpacing(layer: segment.layer, units: input.unitsPerMicron, width: retainedWidth, explicitSpecialWidth: routeClass == .special, areaHandledSeparately: true).spacing)
                    guard try geometry.routingSpacingRules[Int16(segment.layer)]?.usesParallelRunLength == true || Self.clear(region, layer: segment.layer, obstacles: occupancy.filter { $0.blockage || $0.netID != route.netID }, spacing: spacing, rule: geometry.routingSpacingRules[Int16(segment.layer)], budget: &budget) else {
                        throw Failure(code: "routing_retained_geometry_invalid", message: "Retained conductor intersects excluded source geometry or violates clearance.")
                    }
                    occupancy.append(try Self.occupied(layer: segment.layer, region: region, netID: route.netID, geometry: geometry, budget: &budget))
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
                    : max(constraints.routeSpacing, try geometry.routingWidthAndSpacing(layer: Int(shape.layer), units: input.unitsPerMicron, width: requestedWidth, areaHandledSeparately: true).spacing)
                guard try geometry.routingSpacingRules[shape.layer]?.usesParallelRunLength == true || Self.clear(Region(layer: shape.layer, polygons: [shape]), layer: Int(shape.layer), obstacles: occupancy.filter { $0.blockage || $0.netID != via.netID }, spacing: sourceClearance, rule: geometry.routingSpacingRules[shape.layer], budget: &budget) else {
                    throw Failure(code: "routing_retained_geometry_invalid", message: "Retained fixed contact intersects excluded source geometry or violates clearance.")
                }
            }
            try Self.appendMetal(via, geometry: geometry, to: &occupancy, budget: &budget)
        }
        try geometry.validateRoutingCuts(output.vias, sourceCuts: sourceCuts)
        try Self.coalesceMetal(&occupancy, geometry: geometry, budget: &budget)
        try Self.replayMetalSpacing(occupancy, geometry: geometry, minimum: constraints.routeSpacing, budget: &budget)
        let eligibleLayers = layers
        var reservationBound = 0
        for net in nets { reservationBound = try Self.add(reservationBound, net.pinIDs.count) }
        try budget.extend(reservationBound); try budget.charge(reservationBound)
        var reservations: [Occupancy] = []
        var reservedContacts: [PhysicalDesignRoutingContactHistory.Contact] = []
        var reservedTerminalCount = 0
        var contactRequiredNets: Set<String> = []
        // Both phases use the same access predicates; only the second constructs routes.
        for reserving in [true, false] {
        var phaseNets = nets
        if !reserving {
            try budget.admitSort(nets.count)
            phaseNets.sort {
                let first = contactRequiredNets.contains($0.id), second = contactRequiredNets.contains($1.id)
                return first == second ? $0.id < $1.id : first
            }
        }
        for net in phaseNets {
            try Task.checkCancellation()
            guard let routeClass = net.routingClass else {
                throw Failure(code: "routing_net_class_unsupported", message: "Native routing requires an explicitly qualified net container.")
            }
            let layers: [Int]
            if routeClass == .special {
                let access = Set(input.pins.filter { net.pinIDs.contains($0.id) }.compactMap(\.accessLayer))
                guard access.count == 1, let layer = access.first, eligibleLayers.contains(layer) else {
                    throw Failure(code: "routing_special_layer_unsupported", message: "Finite special routing requires one common eligible source PORT layer.")
                }
                layers = [layer]
            } else { layers = eligibleLayers }
            var widths: [Int: Int64] = [:]
            var clearances: [Int: Int64] = [:]
            for layer in layers {
                let resolved = try geometry.routingWidthAndSpacing(layer: layer, units: input.unitsPerMicron,
                    width: requestedWidth, explicitSpecialWidth: routeClass == .special, areaHandledSeparately: true)
                widths[layer] = resolved.width
                clearances[layer] = max(constraints.routeSpacing, resolved.spacing)
            }
            // Every lookup below uses an eligible, validated layer from this immutable net-local table.
            func resolvedWidth(on layer: Int) -> Int64 { widths[layer]! }
            let terminals = try net.pinIDs.sorted().map { id -> PhysicalDesignSnapshot.Pin in
                guard let pin = pins[id], pin.netID == net.id,
                      pin.cellID.map({ cells[$0] != nil }) ?? (pin.topPort != nil),
                      let layer = pin.accessLayer, layers.contains(layer), ports[id] != nil else {
                    throw Failure(code: "routing_pin_source_invalid", message: "Net \(net.id) requires exact cell or top PORTs, explicit layers and matching terminal identities.")
                }
                return pin
            }
            guard terminals.count >= 2 else { throw Failure(code: "routing_connectivity_missing", message: "Each selected net requires at least two source terminals.") }
            let relevantCount = try Self.add(occupancy.count, reservations.count)
            try budget.extend(Self.multiply(relevantCount, 2)); try budget.charge(Self.multiply(relevantCount, 2))
            var relevant = occupancy.filter { $0.blockage || $0.netID != net.id }
            for reservation in reservations where reservation.netID != net.id { relevant.append(reservation) }
            try Self.coalesceMetal(&relevant, geometry: geometry, budget: &budget)
            func reservedCutsFit(_ candidate: PhysicalDesignSnapshot.Via, shapes: [IRBoundary],
                                 budget run: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
                for prior in reservedContacts {
                    try run.extend(1); try run.admit()
                    if prior.via.netID != candidate.netID,
                       try !geometry.routingCutPairFits(candidate, shapes: shapes, against: prior.via,
                           otherShapes: prior.shapes, budget: &run) { return false }
                }
                return true
            }
            let events = try Self.events(core: core, terminals: terminals, ports: ports, occupancy: relevant,
                geometry: geometry, tracks: tracks, widths: widths.values.sorted(), clearance: clearances.values.max() ?? 0, budget: &budget)
            let xs = events.x, ys = events.y
            let xy = try Self.multiply(xs.count, ys.count)
            try budget.admitSort(geometry.vias.count)
            let masterNames = geometry.vias.keys.sorted().filter {
                let source = geometry.vias[$0]!
                return source.definition.isDefault && layers.contains(Int(source.lowerLayer)) && layers.contains(Int(source.upperLayer))
            }
            let masterCount = max(1, masterNames.count)
            let accessBound = try Self.multiply(Self.multiply(Self.multiply(terminals.count, xy), layers.count), masterCount)
            let states = try Self.multiply(layers.count, xy)
            let searchBound = try Self.multiply(Self.multiply(Self.multiply(terminals.count - 1, states), Self.add(layers.count, 3)), masterCount)
            let arenaBound = try Self.add(accessBound, searchBound)
            var history = PhysicalDesignRoutingContactHistory(maximumContacts: arenaBound, maximumHistories: arenaBound)
            var accessCount = 0
            try budget.extend(accessBound)
            func point(_ node: Node) -> (Int64, Int64) { (xs[node.x], ys[node.y]) }
            func onTrack(_ node: Node) -> Bool {
                Self.onTrack(x: xs[node.x], y: ys[node.y], layer: node.layer, tracks: tracks)
            }
            func clear(_ region: Region, layer: Int) throws -> Bool {
                try Self.clear(region, layer: layer, obstacles: relevant, spacing: clearances[layer] ?? 0, rule: geometry.routingSpacingRules[Int16(layer)], budget: &budget)
            }
            try budget.extend(terminals.count); try budget.charge(terminals.count)
            var accesses: [[Access]] = []
            accesses.reserveCapacity(terminals.count)
            for terminal in terminals {
                let layer = terminal.accessLayer!
                let port = Region(layer: Int16(layer), polygons: ports[terminal.id, default: []].filter { Int($0.layer) == layer })
                var candidates: [Access] = []
                for x in xs.indices {
                    for y in ys.indices {
                        try budget.admit()
                        let node = Node(x: x, y: y, layer: layer)
                        guard onTrack(node) else { continue }
                        let cap = try Self.cap(x: xs[x], y: ys[y], width: resolvedWidth(on: layer), layer: layer)
                        if try Self.fits(cap, core: core) && cap.subtracting(port).isEmpty && clear(cap, layer: layer) {
                            guard accessCount < accessBound else { throw Failure(code: "routing_candidate_budget_exhausted", message: "The finite access arena allowance was exhausted.") }
                            try budget.extend(1); try budget.admit()
                            candidates.append(.init(node: node, contact: nil)); accessCount += 1
                        }
                    }
                }
                if candidates.isEmpty, routeClass == .regular {
                    for neighbor in layers where neighbor != layer {
                        for x in xs.indices { for y in ys.indices {
                            try budget.admit()
                            let seed = Node(x: x, y: y, layer: neighbor)
                            guard onTrack(seed) else { continue }
                            for name in masterNames {
                                try budget.extend(1); try budget.admit()
                                guard let source = geometry.vias[name], Int(source.lowerLayer) == min(layer, neighbor),
                                      Int(source.upperLayer) == max(layer, neighbor) else { continue }
                                let requested = PhysicalDesignSnapshot.Via(id: "terminal-access", netID: net.id,
                                    x: xs[x], y: ys[y], lowerLayer: min(layer, neighbor), upperLayer: max(layer, neighbor), master: name)
                                var selectedContact: Int?
                                _ = try PhysicalDesignFixedViaSelection.select(requested, within: core,
                                    geometry: geometry, budget: &budget) { candidate, shapes, run in
                                    let terminalMetal = Region(layer: Int16(layer), polygons: shapes.filter { Int($0.layer) == layer })
                                    var terminalVertices = 0, contactVertices = 0
                                    for polygon in port.polygons { terminalVertices = try Self.add(terminalVertices, polygon.points.count) }
                                    for polygon in terminalMetal.polygons { contactVertices = try Self.add(contactVertices, polygon.points.count) }
                                    let containmentWork = try Self.add(terminalVertices, Self.multiply(terminalVertices, contactVertices))
                                    try run.extend(containmentWork); try run.charge(containmentWork)
                                    guard !terminalMetal.isEmpty, try terminalMetal.subtracting(port).isEmpty else { return false }
                                    let cap = try Self.cap(x: candidate.x, y: candidate.y, width: resolvedWidth(on: neighbor), layer: neighbor)
                                    guard try Self.fits(cap, core: core) else { return false }
                                    var gridWork = cap.polygons.reduce(0) { $0 + $1.points.count }
                                    for shape in shapes { gridWork = try Self.add(gridWork, shape.points.count) }
                                    try run.extend(gridWork); try run.charge(gridWork)
                                    do {
                                        for shape in shapes { try geometry.manufacturingGrid.validate(shape, field: "terminal fixed VIA") }
                                        for shape in cap.polygons { try geometry.manufacturingGrid.validate(shape, field: "terminal neighboring cap") }
                                    } catch PhysicalDesignTechnologyError.invalid { return false }
                                    for metalLayer in [layer, neighbor] {
                                        let metal = Region(layer: Int16(metalLayer), polygons: shapes.filter { Int($0.layer) == metalLayer })
                                        if metalLayer == neighbor, try metal.intersection(cap).isEmpty { return false }
                                        if try !Self.clear(metal, layer: metalLayer, obstacles: relevant,
                                            spacing: clearances[metalLayer] ?? 0, rule: geometry.routingSpacingRules[Int16(metalLayer)], budget: &run) { return false }
                                    }
                                    if try !Self.clear(cap, layer: neighbor, obstacles: relevant,
                                        spacing: clearances[neighbor] ?? 0, rule: geometry.routingSpacingRules[Int16(neighbor)], budget: &run) { return false }
                                    for shape in shapes where geometry.sourceLayers[shape.layer]?.type == .cut {
                                        if try !Self.clear(Region(layer: shape.layer, polygons: [shape]), layer: Int(shape.layer),
                                            obstacles: relevant, spacing: Int64(geometry.cutSpacings[shape.layer] ?? 0), budget: &run) { return false }
                                    }
                                    guard try PhysicalDesignFixedViaSelection.cutsFit(shapes, geometry: geometry,
                                        against: output.vias, sourceCuts: sourceCuts, budget: &run) else { return false }
                                    guard try reservedCutsFit(candidate, shapes: shapes, budget: &run) else { return false }
                                    selectedContact = try history.retain(candidate, shapes: shapes, budget: &run)
                                    return true
                                }
                                if let selectedContact {
                                    guard accessCount < accessBound else { throw Failure(code: "routing_candidate_budget_exhausted", message: "The finite access arena allowance was exhausted.") }
                                    try budget.extend(1); try budget.admit()
                                    candidates.append(.init(node: seed, contact: selectedContact)); accessCount += 1
                                }
                            }
                        } }
                    }
                }
                guard !candidates.isEmpty else { throw Failure(code: "routing_pin_access_unavailable", message: "Terminal \(terminal.id) has no legal full-width track or contained fixed-contact access in its source PORT.") }
                accesses.append(candidates)
            }
            if reserving {
                try budget.extend(Self.add(accesses.count, 1)); try budget.charge(Self.add(accesses.count, 1))
                if accesses.contains(where: { $0.first?.contact != nil }) { contactRequiredNets.insert(net.id) }
                for candidates in accesses {
                    guard reservedTerminalCount < reservationBound, let chosen = candidates.first else {
                        throw Failure(code: "routing_candidate_budget_exhausted", message: "The finite terminal reservation allowance was exhausted.")
                    }
                    try budget.extend(1); try budget.admit()
                    reservedTerminalCount += 1
                    let center = point(chosen.node)
                    let cap = try Self.cap(x: center.0, y: center.1, width: resolvedWidth(on: chosen.node.layer), layer: chosen.node.layer)
                    var capWork = 1
                    for shape in cap.polygons { capWork = try Self.add(capWork, try Self.add(1, shape.points.count)) }
                    try budget.extend(capWork); try budget.charge(capWork)
                    reservations.append(try Self.occupied(layer: chosen.node.layer, region: cap, netID: net.id,
                        geometry: geometry, budget: &budget))
                    if let index = chosen.contact {
                        let contact = history.contacts[index]
                        var contactWork = 1
                        for shape in contact.shapes { contactWork = try Self.add(contactWork, try Self.add(1, shape.points.count)) }
                        try budget.extend(contactWork); try budget.charge(contactWork)
                        // Retain the already translated immutable shapes for exact cut-pair probes.
                        reservedContacts.append(contact)
                        for shape in contact.shapes where geometry.sourceLayers[shape.layer]?.type == .routing {
                            reservations.append(try Self.occupied(layer: Int(shape.layer),
                                region: Region(layer: shape.layer, polygons: [shape]), netID: net.id,
                                geometry: geometry, budget: &budget))
                        }
                    }
                }
                continue
            }
            // This graph's complete source/width/occupancy context stays fixed across this net's terminals.
            // New same-net contacts remain exclusively in history and are never a cached static verdict.
            var graph = try PhysicalDesignRoutingEventGraph(xCount: xs.count, yCount: ys.count,
                layers: layers, defaultMasterCount: masterNames.count,
                terminalAccessCount: terminalTrackJogs ? accessCount : 0, budget: &budget)
            for layer in layers {
                let horizontal = tracks.contains { $0.layer == layer && $0.direction.lowercased() == "horizontal" }
                for x in xs.indices { for y in ys.indices {
                    try budget.extend(1); try budget.admit()
                    let node = Node(x: x, y: y, layer: layer)
                    guard onTrack(node) else { continue }
                    let nextX = horizontal ? x + 1 : x, nextY = horizontal ? y : y + 1
                    guard xs.indices.contains(nextX), ys.indices.contains(nextY) else { continue }
                    let next = Node(x: nextX, y: nextY, layer: layer)
                    guard onTrack(next) else { continue }
                    let a = point(node), b = point(next), width = resolvedWidth(on: layer)
                    let segment = PhysicalDesignSnapshot.RouteSegment(id: "candidate", layer: layer,
                        x1: a.0, y1: a.1, x2: b.0, y2: b.1, widthDBU: width,
                        endpointExtensions: .init(beginDBU: width / 2, endDBU: width / 2))
                    let conductor = try Self.conductor(segment, width: width)
                    if bypassingLayers.contains(layer) {
                        var withinTerminal = false
                        for terminal in terminals {
                            let port = Region(layer: Int16(layer), polygons: ports[terminal.id, default: []].filter { Int($0.layer) == layer })
                            if try conductor.subtracting(port).isEmpty { withinTerminal = true; break }
                        }
                        guard withinTerminal else { continue }
                    }
                    guard try Self.fits(conductor, core: core), try clear(conductor, layer: layer) else { continue }
                    try graph.addUndirected(from: node, to: next, contact: nil, budget: &budget)
                } }
            }
            if terminalTrackJogs {
            var jogNodes: Set<Node> = []
            for candidates in accesses { for access in candidates {
                try budget.extend(2); try budget.charge(2)
                let node = access.node
                guard !bypassingLayers.contains(node.layer), jogNodes.insert(node).inserted else { continue }
                let horizontal = tracks.contains { $0.layer == node.layer && $0.direction.lowercased() == "horizontal" }
                let coordinates = horizontal ? ys : xs
                for direction in [1, -1] {
                    var index = (horizontal ? node.y : node.x) + direction
                    while coordinates.indices.contains(index) {
                        try budget.extend(1); try budget.admit()
                        let neighbor = Node(x: horizontal ? node.x : index, y: horizontal ? index : node.y, layer: node.layer)
                        if onTrack(neighbor) {
                            guard try Self.adjacentDeclaredTracks(coordinates[horizontal ? node.y : node.x],
                                coordinates[index], layer: node.layer, tracks: tracks, budget: &budget) else { break }
                            let a = point(node), b = point(neighbor), width = resolvedWidth(on: node.layer)
                            let segment = PhysicalDesignSnapshot.RouteSegment(id: "terminal-jog", layer: node.layer,
                                x1: a.0, y1: a.1, x2: b.0, y2: b.1, widthDBU: width,
                                endpointExtensions: .init(beginDBU: width / 2, endDBU: width / 2))
                            let conductor = try Self.conductor(segment, width: width)
                            var gridWork = 0
                            for shape in conductor.polygons { gridWork = try Self.add(gridWork, shape.points.count) }
                            try budget.extend(gridWork); try budget.charge(gridWork)
                            var gridValid = true
                            do { for shape in conductor.polygons { try geometry.manufacturingGrid.validate(shape, field: "terminal track jog") } }
                            catch PhysicalDesignTechnologyError.invalid { gridValid = false }
                            if gridValid, try Self.fits(conductor, core: core), try clear(conductor, layer: node.layer) {
                                try graph.addUndirected(from: node, to: neighbor, contact: nil, budget: &budget)
                            }
                            break
                        }
                        index += direction
                    }
                }
            } }
            }
            for x in xs.indices { for y in ys.indices {
                for name in masterNames {
                    try budget.extend(1); try budget.admit()
                    let source = geometry.vias[name]!
                    let lower = Node(x: x, y: y, layer: Int(source.lowerLayer))
                    let upper = Node(x: x, y: y, layer: Int(source.upperLayer))
                    guard onTrack(lower), onTrack(upper) else { continue }
                    let requested = PhysicalDesignSnapshot.Via(id: "candidate", netID: net.id, x: xs[x], y: ys[y],
                        lowerLayer: lower.layer, upperLayer: upper.layer, master: name)
                    var selectedContact: Int?
                    _ = try PhysicalDesignFixedViaSelection.select(requested, within: core, geometry: geometry, budget: &budget) { candidate, shapes, viaBudget in
                        for layer in [lower.layer, upper.layer] {
                            let metal = Region(layer: Int16(layer), polygons: shapes.filter { Int($0.layer) == layer })
                            let cap = try Self.cap(x: candidate.x, y: candidate.y, width: resolvedWidth(on: layer), layer: layer)
                            if try metal.intersection(cap).isEmpty || !Self.clear(metal, layer: layer, obstacles: relevant,
                                spacing: clearances[layer] ?? 0, rule: geometry.routingSpacingRules[Int16(layer)], budget: &viaBudget) { return false }
                        }
                        for shape in shapes where geometry.sourceLayers[shape.layer]?.type == .cut {
                            let cut = Region(layer: shape.layer, polygons: [shape])
                            if try !Self.clear(cut, layer: Int(shape.layer), obstacles: relevant,
                                spacing: Int64(geometry.cutSpacings[shape.layer] ?? 0), budget: &viaBudget) { return false }
                        }
                        guard try PhysicalDesignFixedViaSelection.cutsFit(shapes, geometry: geometry,
                            against: output.vias, sourceCuts: sourceCuts, budget: &viaBudget) else { return false }
                        guard try reservedCutsFit(candidate, shapes: shapes, budget: &viaBudget) else { return false }
                        selectedContact = try history.retain(candidate, shapes: shapes, budget: &viaBudget)
                        return true
                    }
                    if let selectedContact {
                        try graph.addUndirected(from: lower, to: upper, contact: selectedContact, budget: &budget)
                    }
                }
            } }
            var segments: [PhysicalDesignSnapshot.RouteSegment] = []
            try budget.extend(terminals.count - 1); try budget.charge(terminals.count - 1)
            var paths: [Range<Int>] = []
            paths.reserveCapacity(terminals.count - 1)
            try budget.extend(terminals.count); try budget.charge(terminals.count)
            var terminalPoints: [(x: Int64, y: Int64)] = []
            terminalPoints.reserveCapacity(terminals.count)
            var contacts: [PhysicalDesignSnapshot.Via] = []
            var root: Node?
            var rootAccess: Int?
            var committedHistory = 0
            var labelsUsed = 0
            for targetOrdinal in 1..<terminals.count {
                var targets: [Node: [Int]] = [:]
                try budget.extend(accesses[targetOrdinal].count); try budget.charge(accesses[targetOrdinal].count)
                var targetNodes: [Node] = []
                targetNodes.reserveCapacity(accesses[targetOrdinal].count)
                for index in accesses[targetOrdinal].indices {
                    try budget.extend(2); try budget.charge(2)
                    let node = accesses[targetOrdinal][index].node
                    targets[node, default: []].append(index)
                    targetNodes.append(node)
                }
                let distances = try graph.reverseDistances(targets: targetNodes, budget: &budget)
                func remaining(_ node: Node) throws -> Int? {
                    try budget.extend(1); try budget.admit()
                    let value = distances[try graph.index(of: node)]
                    return value < 0 ? nil : value
                }
                var search = PhysicalDesignRoutingSearch(maximumLabels: searchBound - labelsUsed)
                for index in accesses[0].indices where rootAccess == nil || rootAccess == index {
                    let access = accesses[0][index]
                    guard let distance = try remaining(access.node),
                          try history.fits(access.contact, history: committedHistory, geometry: geometry, budget: &budget) else { continue }
                    let initial = try history.adding(access.contact, to: committedHistory, budget: &budget)
                    try search.append(node: access.node, rootAccess: index, history: initial,
                        previous: nil, contact: nil, remaining: distance, budget: &budget) { first, second, run in
                        try history.isSubset(first, of: second, budget: &run)
                    }
                }
                var found: (label: Int, targetAccess: Int, history: Int)?
                while let labelIndex = try search.next(budget: &budget) {
                    let label = search.labels[labelIndex]
                    let node = label.node
                    if label.previous != nil {
                        for index in targets[node, default: []] {
                            try budget.extend(1); try budget.admit()
                            let access = accesses[targetOrdinal][index]
                            guard try history.fits(access.contact, history: label.history, geometry: geometry, budget: &budget) else { continue }
                            found = (labelIndex, index, try history.adding(access.contact, to: label.history, budget: &budget))
                            break
                        }
                        if found != nil { break }
                    }
                    var edgeIndex = try graph.firstEdge(from: node, budget: &budget)
                    while let index = edgeIndex {
                        let edge = try graph.edge(at: index, budget: &budget)
                        edgeIndex = edge.next
                        guard let distance = try remaining(edge.destination) else { continue }
                        guard try history.fits(edge.contact, history: label.history, geometry: geometry, budget: &budget) else { continue }
                        let nextHistory = try history.adding(edge.contact, to: label.history, budget: &budget)
                        try search.append(node: edge.destination, rootAccess: label.rootAccess, history: nextHistory,
                            previous: labelIndex, contact: edge.contact, remaining: distance, budget: &budget) { first, second, run in
                            try history.isSubset(first, of: second, budget: &run)
                        }
                    }
                }
                labelsUsed = try Self.add(labelsUsed, search.labels.count)
                guard let found else { throw Failure(code: "routing_path_unavailable", message: "No legal conductor/contact continuation remains in the admitted event/history domain for net \(net.id).") }
                committedHistory = found.history
                var endIndex = found.label
                let targetPoint = point(accesses[targetOrdinal][found.targetAccess].node)
                try budget.extend(1); try budget.admit()
                terminalPoints.append((targetPoint.0, targetPoint.1))
                if let pinIndex = output.pins.firstIndex(where: { $0.id == terminals[targetOrdinal].id }) {
                    output.pins[pinIndex].x = targetPoint.0; output.pins[pinIndex].y = targetPoint.1
                }
                let pathStart = segments.count
                while let previousIndex = search.labels[endIndex].previous {
                    try budget.extend(1); try budget.admit()
                    let end = search.labels[endIndex], previous = search.labels[previousIndex]
                    let a = point(previous.node), b = point(end.node)
                    if end.contact == nil {
                        let width = resolvedWidth(on: end.node.layer)
                        try budget.extend(1); try budget.admit()
                        segments.append(.init(id: "route_\(net.id)_segment_\(segments.count)", layer: end.node.layer,
                            x1: a.0, y1: a.1, x2: b.0, y2: b.1, widthDBU: width, endpointExtensions: .init(beginDBU: width / 2, endDBU: width / 2)))
                    }
                    endIndex = previousIndex
                }
                root = search.labels[endIndex].node
                rootAccess = search.labels[endIndex].rootAccess
                try budget.extend(1); try budget.admit()
                paths.append(pathStart..<segments.count)
            }
            try history.forEachContact(in: committedHistory, budget: &budget) { _, selected in
                var via = selected
                via.id = "route_\(net.id)_via_\(contacts.count)"
                contacts.append(via)
            }
            if let root {
                let sourcePoint = point(root)
                try budget.extend(1); try budget.admit()
                terminalPoints.append((sourcePoint.0, sourcePoint.1))
            }
            let protectedCapacity = try Self.add(Self.multiply(terminalPoints.count, layers.count), Self.multiply(contacts.count, 2))
            try budget.extend(protectedCapacity); try budget.charge(protectedCapacity)
            var protectedPoints: Set<PhysicalDesignGeneratedRouteNormalizer.Point> = []
            protectedPoints.reserveCapacity(protectedCapacity)
            for terminal in terminalPoints {
                for layer in layers {
                    try budget.extend(1); try budget.admit()
                    protectedPoints.insert(.init(x: terminal.x, y: terminal.y, layer: layer))
                }
            }
            for contact in contacts {
                for layer in [contact.lowerLayer, contact.upperLayer] {
                    try budget.extend(1); try budget.admit()
                    protectedPoints.insert(.init(x: contact.x, y: contact.y, layer: layer))
                }
            }
            segments = try PhysicalDesignGeneratedRouteNormalizer.normalize(segments, paths: paths,
                protectedPoints: protectedPoints, budget: &budget)
            guard !segments.isEmpty, let root else { throw Failure(code: "routing_connectivity_missing", message: "Collocated terminals cannot be represented by a nonempty routed conductor.") }
            let rootPoint = point(root)
            if let pinIndex = output.pins.firstIndex(where: { $0.id == terminals[0].id }) { output.pins[pinIndex].x = rootPoint.0; output.pins[pinIndex].y = rootPoint.1 }
            // Validate all path contacts before publishing any net geometry; no center-distance proxy.
            try geometry.validateRoutingCuts(output.vias + contacts, sourceCuts: sourceCuts)
            for segment in segments { occupancy.append(try Self.occupied(layer: segment.layer, region: Self.conductor(segment, width: resolvedWidth(on: segment.layer)), netID: net.id, geometry: geometry, budget: &budget)) }
            for via in contacts { try Self.appendMetal(via, geometry: geometry, to: &occupancy, budget: &budget) }
            try Self.coalesceMetal(&occupancy, geometry: geometry, budget: &budget)
            output.vias.append(contentsOf: contacts)
            output.routes.append(.init(id: "route_\(net.id)", netID: net.id, segments: segments, defStatus: .routed, defShape: nil))
        }
        }
        try Self.repairMetalArea(&output, occupancy: &occupancy, selected: selected, core: core,
            geometry: geometry, minimumSpacing: constraints.routeSpacing, budget: &budget)
        try Self.replayMetalSpacing(occupancy, geometry: geometry, minimum: constraints.routeSpacing, budget: &budget)
        try geometry.validate(output)
        var state = output.implementationState ?? .init()
        if output.routes != input.routes || output.vias != input.vias { state.repairProofs.removeAll() }
        state.routingEvidence = .init(mode: mode, routedNetCount: nets.count, skippedNetIDs: clockNets.sorted(), viaCount: output.vias.count)
        output.implementationState = state
        output.metadata["routingStatus"] = mode
        return .init(snapshot: output, checks: budget.checks, structuralCeiling: budget.capacity)
    }

    /// Admits the complete special-net deletion set before geometry or route evidence is discarded.
    /// The same gate protects direct routing and cell mutations whose invalidation deletes all routes.
    static func validateSpecialNetMutation(_ snapshot: PhysicalDesignSnapshot, selectedNetIDs: Set<String>,
        configuration: PhysicalDesignConfiguration, geometry: PhysicalDesignProcessGeometry) throws {
        let selected = snapshot.nets.filter { selectedNetIDs.contains($0.id) && $0.routingClass == .special }
        guard !selected.isEmpty else { return }
        try Task.checkCancellation()
        guard configuration.implementationConstraints?.sourceRoutingWidthPolicy != .sourceDefault else {
            throw Failure(code: "routing_special_width_policy_unsupported", message: "Source-default regular routing cannot select explicit-width special-net mutation.")
        }
        guard let constraints = configuration.implementationConstraints, constraints.routeWidth > 0,
              constraints.routeWidth.isMultiple(of: 2) else {
            throw Failure(code: "routing_special_width_required", message: "Finite special routing requires an explicit even positive generation width.")
        }
        let specialIDs = Set(selected.map(\.id))
        guard !snapshot.vias.contains(where: { specialIDs.contains($0.netID) }) else {
            // FIXME(INCOMPLETE_IMPLEMENTATION): Special-net contact serialization has no retained route-profile owner. Native API/CLI mutation refuses special contacts until exact status/width/contact ownership and standard export are implemented together.
            throw Failure(code: "routing_special_via_unsupported", message: "Finite special routing supports wires on one source layer, without special contacts.")
        }
        var accessLayers: [String: Int] = [:]
        for net in selected {
            try Task.checkCancellation()
            let terminals = snapshot.pins.filter { net.pinIDs.contains($0.id) }
            let layers = Set(terminals.compactMap(\.accessLayer))
            guard terminals.count == net.pinIDs.count, layers.count == 1, let layer = layers.first,
                  terminals.allSatisfy({ $0.accessLayer == layer }),
                  configuration.preferredRoutingLayers.contains(layer), layer <= configuration.maximumRoutingLayer else {
                throw Failure(code: "routing_special_layer_unsupported", message: "Finite special routing requires all original terminals on one selected source routing layer.")
            }
            accessLayers[net.id] = layer
            _ = try geometry.routingWidthAndSpacing(layer: layer, units: snapshot.unitsPerMicron,
                width: constraints.routeWidth, explicitSpecialWidth: true)
        }
        for route in snapshot.routes where specialIDs.contains(route.netID) {
            try Task.checkCancellation()
            guard route.defStatus == .routed, route.defShape == nil else {
                throw Failure(code: "routing_special_route_protected", message: "Only unshielded ROUTED special wires without SHAPE may be replaced; fixed or shaped ownership remains unchanged.")
            }
            for segment in route.segments {
                guard segment.layer == accessLayers[route.netID] else {
                    throw Failure(code: "routing_special_layer_unsupported", message: "Selected special conductors must retain the common terminal layer without requiring contacts.")
                }
                guard let width = segment.widthDBU, width == constraints.routeWidth else {
                    throw Failure(code: "routing_special_width_mismatch", message: "Explicit special generation width must equal every selected retained conductor width.")
                }
                _ = try segment.qualifiedFootprint()
                _ = try geometry.routingWidthAndSpacing(layer: segment.layer, units: snapshot.unitsPerMicron,
                    width: width, explicitSpecialWidth: true)
            }
        }
    }

    static func conductor(_ segment: PhysicalDesignSnapshot.RouteSegment, width: Int64) throws -> Region {
        guard segment.widthDBU == width else {
            throw Failure(code: "routing_width_unsupported", message: "Conductor width must equal its retained qualified width.")
        }
        do { return try rectangle(segment.qualifiedFootprint(), layer: segment.layer) }
        catch let error as PhysicalDesignRouteEndpointExtensions.GeometryError {
            throw Failure(code: "routing_endpoint_geometry_invalid", message: "Retained conductor \(segment.id) has invalid or unqualified endpoint geometry: \(error).")
        }
    }
    /// Native conservative exclusion policy; standard DEF blockages remain PLACEMENT.
    static func blockageLayers(_ snapshot: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration) -> Set<Int> {
        Set((snapshot.implementationState?.tracks ?? []).filter {
            configuration.preferredRoutingLayers.contains($0.layer) && $0.layer <= configuration.maximumRoutingLayer
        }.map(\.layer))
    }

    /// Admits retained actual geometry without editing or approximating a route/contact.
    static func validateRetainedBlockages(_ snapshot: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration, geometry: PhysicalDesignProcessGeometry?) throws {
        try Task.checkCancellation()
        guard !snapshot.blockages.isEmpty, !snapshot.routes.isEmpty || !snapshot.vias.isEmpty else { return }
        let layers = blockageLayers(snapshot, configuration: configuration)
        guard !layers.isEmpty else {
            throw Failure(code: "eco_blockage_layers_missing", message: "Retained geometry requires declared eligible metal-layer tracks for native blockage admission.")
        }
        var shapeCount = 0
        for route in snapshot.routes {
            for segment in route.segments where layers.contains(segment.layer) { shapeCount = try add(shapeCount, 1) }
        }
        for via in snapshot.vias {
            try Task.checkCancellation()
            guard let master = via.master, let source = geometry?.vias[master] else {
                throw Failure(code: "eco_blockage_via_source_missing", message: "Retained contact blockage admission requires its exact fixed source geometry.")
            }
            for shape in source.shapes where layers.contains(Int(shape.layer)) { shapeCount = try add(shapeCount, 1) }
        }
        var budget = PhysicalDesignRoutingWorkBudget(caller: configuration.maximumRoutingCandidateChecks)
        try budget.extend(try add(try multiply(shapeCount, try add(snapshot.blockages.count, 1)), snapshot.vias.count))
        func admit(_ region: Region, layer: Int, budget: inout PhysicalDesignRoutingWorkBudget) throws {
            for rect in snapshot.blockages {
                try budget.admit()
                if try !region.intersection(rectangle(rect, layer: layer)).isEmpty {
                    throw Failure(code: "eco_blockage_route_intersection", message: "A retained conductor/contact intersects the native profile's applicable blockage area.")
                }
            }
        }
        for route in snapshot.routes {
            for segment in route.segments where layers.contains(segment.layer) {
                try budget.admit()
                guard let width = segment.widthDBU else {
                    throw Failure(code: "eco_blockage_width_missing", message: "Retained conductor blockage admission requires its qualified width.")
                }
                try admit(conductor(segment, width: width), layer: segment.layer, budget: &budget)
            }
        }
        for via in snapshot.vias {
            try budget.admit()
            guard let master = via.master, let geometry else {
                throw Failure(code: "eco_blockage_via_source_missing", message: "Retained contact requires its exact fixed source geometry.")
            }
            for shape in try geometry.viaShapes(master: master, x: via.x, y: via.y) where layers.contains(Int(shape.layer)) {
                try budget.admit()
                try admit(Region(layer: shape.layer, polygons: [shape]), layer: Int(shape.layer), budget: &budget)
            }
        }
    }

    static func cap(x: Int64, y: Int64, width: Int64, layer: Int) throws -> Region {
        try box(minX: subtract(x, width / 2), minY: subtract(y, width / 2), maxX: add(x, width / 2), maxY: add(y, width / 2), layer: layer)
    }
    static func rectangle(_ rect: PhysicalDesignSnapshot.Rect, layer: Int) throws -> Region {
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
    private static func clear(_ region: Region, layer: Int, obstacles: [Occupancy], spacing: Int64,
        rule: PhysicalDesignRoutingSpacingRule? = nil, budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        guard let minimum = Int32(exactly: spacing) else { throw Failure(code: "routing_coordinate_overflow", message: "Spacing exceeds the integer backend.") }
        let object = rule?.usesParallelRunLength == true ? try PhysicalDesignRoutingSpacingObject.compile(region, budget: &budget) : nil
        for obstacle in obstacles where obstacle.layer == layer {
            if try !clearObject(region, object: object, obstacle: obstacle, minimum: minimum, rule: rule, budget: &budget) { return false }
        }
        return true
    }
    private static func clearObject(_ region: Region, object: PhysicalDesignRoutingSpacingObject?, obstacle: Occupancy, minimum: Int32,
        rule: PhysicalDesignRoutingSpacingRule?, budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        if !obstacle.blockage, let rule, rule.usesParallelRunLength {
            guard let object, let other = obstacle.spacingObject else { throw Failure(code: "routing_spacing_geometry_invalid", message: "Table checks require exact union geometry.") }
            return try PhysicalDesignRoutingSpacingGeometry.separated(object, from: other, rule: rule, minimum: Int64(minimum), obstacleWidthOverride: obstacle.spacingWidthOverride, budget: &budget)
        }
        if try !region.intersection(obstacle.region).isEmpty { return false }
        return try obstacle.blockage || minimum == 0 || region.spaceViolations(to: obstacle.region, minSpace: minimum).isEmpty
    }
    private static func appendMetal(_ via: PhysicalDesignSnapshot.Via, geometry: PhysicalDesignProcessGeometry, to occupancy: inout [Occupancy],
        budget: inout PhysicalDesignRoutingWorkBudget) throws {
        guard let master = via.master else { throw Failure(code: "routing_via_source_invalid", message: "Retained via has no exact master.") }
        let shapes = try geometry.viaShapes(master: master, x: via.x, y: via.y)
        for layer in [via.lowerLayer, via.upperLayer] {
            occupancy.append(try occupied(layer: layer, region: Region(layer: Int16(layer), polygons: shapes.filter { Int($0.layer) == layer }), netID: via.netID, geometry: geometry, budget: &budget))
        }
    }
    static func adjacentDeclaredTracks(_ first: Int64, _ second: Int64, layer: Int,
        tracks: [PhysicalDesignImplementationState.Track], budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        for track in tracks {
            try budget.extend(1); try budget.admit()
            guard track.layer == layer, track.spacing > 0, track.count > 0 else { continue }
            let (a, overflowA) = first.subtractingReportingOverflow(track.origin)
            let (b, overflowB) = second.subtractingReportingOverflow(track.origin)
            guard !overflowA, !overflowB, a >= 0, b >= 0,
                  a % track.spacing == 0, b % track.spacing == 0,
                  a / track.spacing < track.count, b / track.spacing < track.count else { continue }
            let firstOrdinal = a / track.spacing, secondOrdinal = b / track.spacing
            if firstOrdinal > secondOrdinal ? firstOrdinal - secondOrdinal == 1 : secondOrdinal - firstOrdinal == 1 { return true }
        }
        return false
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
        occupancy: [Occupancy], geometry: PhysicalDesignProcessGeometry, tracks: [PhysicalDesignImplementationState.Track], widths: [Int64], clearance: Int64, budget: inout PhysicalDesignRoutingWorkBudget) throws -> (x: [Int64], y: [Int64]) {
        // Width-dependent event expansion uses the invocation's existing cumulative budget.
        try budget.extend(widths.count); try budget.charge(widths.count)
        let halves = Set(widths.map { $0 / 2 }).sorted()
        guard let half = halves.first else { throw Failure(code: "routing_width_unsupported", message: "Source routing requires validated layer widths.") }
        let xMin = try add(core.x, half), xMax = try subtract(add(core.x, core.width), half)
        let yMin = try add(core.y, half), yMax = try subtract(add(core.y, core.height), half)
        guard xMin <= xMax, yMin <= yMax else { throw Failure(code: "routing_core_boundary_conflict", message: "The core cannot contain a full-width conductor.") }
        var x: Set<Int64> = [xMin, xMax], y: Set<Int64> = [yMin, yMax]
        for inset in halves {
            try budget.extend(1); try budget.admit()
            x.insert(try add(core.x, inset)); x.insert(try subtract(add(core.x, core.width), inset))
            y.insert(try add(core.y, inset)); y.insert(try subtract(add(core.y, core.height), inset))
        }
        var extent = halves.last!
        for via in geometry.vias.values where via.definition.isDefault {
            for shape in via.shapes { for p in shape.points { extent = max(extent, abs(Int64(p.x)), abs(Int64(p.y))) } }
        }
        let outer = try add(extent, clearance)
        var offsets: Set<Int64> = [0, outer, -outer]
        for inset in halves { offsets.insert(inset); offsets.insert(-inset) }
        for via in geometry.vias.values where via.definition.isDefault {
            for shape in via.shapes { for point in shape.points {
                try budget.extend(1); try budget.admit()
                offsets.insert(-Int64(point.x)); offsets.insert(-Int64(point.y))
            } }
        }
        for layer in Set(tracks.map(\.layer)) {
            if let rule = geometry.routingSpacingRules[Int16(layer)] {
                try rule.forEachSpacing { spacing in
                    let event = try add(extent, max(clearance, spacing))
                    offsets.insert(event); offsets.insert(-event)
                }
            }
        }
        func insert(_ points: [IRPoint]) throws {
            for point in points {
                try Task.checkCancellation()
                for offset in offsets {
                    try budget.extend(1); try budget.admit()
                    x.insert(try add(Int64(point.x), offset)); y.insert(try add(Int64(point.y), offset))
                }
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

    private static func occupied(layer: Int, region: Region, netID: String?,
        blockage: Bool = false, obstruction: Bool = false, geometry: PhysicalDesignProcessGeometry, budget: inout PhysicalDesignRoutingWorkBudget) throws -> Occupancy {
        let area = geometry.routingMinimumAreas[Int16(layer)] != nil
        let object = (geometry.routingSpacingRules[Int16(layer)]?.usesParallelRunLength == true || area) && !blockage
            ? try PhysicalDesignRoutingSpacingObject.compile(region, budget: &budget, retainingMaterialBands: area) : nil
        var spacingWidth: Int64?
        if obstruction, geometry.obstructionSpacingUsesMinimumWidth,
           geometry.routingSpacingRules[Int16(layer)]?.usesParallelRunLength == true {
            guard let width = geometry.obstructionSpacingWidths[Int16(layer)] else {
                throw Failure(code: "routing_layer_semantics_missing", message: "USEMINSPACING OBS requires a declared minimum routing width.")
            }
            spacingWidth = width
        }
        return .init(layer: layer, region: region, netID: netID, blockage: blockage,
            spacingWidthOverride: spacingWidth, spacingObject: object)
    }

    private static func coalesceMetal(_ occupancy: inout [Occupancy], geometry: PhysicalDesignProcessGeometry,
        budget: inout PhysicalDesignRoutingWorkBudget) throws {
        struct Key: Hashable { let layer: Int; let netID: String }
        try budget.extend(multiply(occupancy.count, 2))
        var groups: [Key: [Occupancy]] = [:], retained: [Occupancy] = []
        for item in occupancy {
            try budget.admit()
            guard !item.blockage, let netID = item.netID,
                  (geometry.routingSpacingRules[Int16(item.layer)]?.usesParallelRunLength == true || geometry.routingMinimumAreas[Int16(item.layer)] != nil) else {
                try budget.admit(); retained.append(item); continue
            }
            try budget.admit()
            groups[Key(layer: item.layer, netID: netID), default: []].append(item)
        }
        try budget.admitSort(groups.count)
        try budget.extend(groups.count)
        for key in groups.keys.sorted(by: { $0.layer == $1.layer ? $0.netID < $1.netID : $0.layer < $1.layer }) {
            let parts = groups[key]!
            try budget.admit()
            if parts.count == 1, parts[0].spacingObject != nil {
                retained.append(parts[0])
            } else {
                var region = Region(layer: Int16(key.layer))
                for part in parts {
                    try budget.extend(part.region.polygons.count)
                    try budget.charge(part.region.polygons.count)
                    region.polygons.append(contentsOf: part.region.polygons)
                }
                retained.append(try occupied(layer: key.layer, region: region, netID: key.netID, geometry: geometry, budget: &budget))
            }
        }
        occupancy = retained
    }

    private static func replayMetalSpacing(_ occupancy: [Occupancy], geometry: PhysicalDesignProcessGeometry,
        minimum: Int64, budget: inout PhysicalDesignRoutingWorkBudget) throws {
        guard let nativeMinimum = Int32(exactly: minimum) else { throw Failure(code: "routing_coordinate_overflow", message: "Spacing exceeds the integer backend.") }
        try budget.extend(multiply(occupancy.count, occupancy.count))
        for metal in occupancy where metal.netID != nil && metal.spacingObject != nil {
            let rule = geometry.routingSpacingRules[Int16(metal.layer)]!
            for other in occupancy where other.layer == metal.layer && other.netID != metal.netID {
                try budget.admit()
                guard try clearObject(metal.region, object: metal.spacingObject, obstacle: other,
                    minimum: nativeMinimum, rule: rule, budget: &budget) else {
                    throw Failure(code: "routing_final_spacing_invalid", message: "Complete same-net metal violates its actual width/parallel-length spacing rule.")
                }
            }
        }
    }
    private static func subtract<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        guard !overflow else { throw Failure(code: "routing_coordinate_overflow", message: "Routing arithmetic overflowed.") }; return value
    }
    private static func multiply<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw Failure(code: "routing_coordinate_overflow", message: "Routing capacity arithmetic overflowed.") }; return value
    }
    private typealias AreaViolation = (item: Int, component: PhysicalDesignRoutingAreaGeometry.Component, minimum: UInt64)

    private static func areaViolations(_ occupancy: [Occupancy], output: PhysicalDesignSnapshot,
        geometry: PhysicalDesignProcessGeometry, budget: inout PhysicalDesignRoutingWorkBudget) throws -> [AreaViolation] {
        var result: [AreaViolation] = []
        for index in occupancy.indices {
            let item = occupancy[index]
            guard let net = item.netID, let rule = geometry.routingMinimumAreas[Int16(item.layer)], let object = item.spacingObject else { continue }
            let components = try PhysicalDesignRoutingAreaGeometry.components(of: object, budget: &budget)
            try budget.extend(components.count); try budget.charge(components.count)
            if components.allSatisfy({ rule.accepts($0.areaDBU2) }) { continue }
            var routed: [PhysicalDesignRoutingSpacingObject.Rectangle] = []
            try budget.extend(output.routes.count); try budget.charge(output.routes.count)
            for route in output.routes where route.netID == net {
                try budget.extend(route.segments.count); try budget.charge(route.segments.count)
                for segment in route.segments where segment.layer == item.layer {
                    try budget.extend(1); try budget.admit()
                    let rect = try segment.qualifiedFootprint()
                    routed.append(.init(minX: rect.x, minY: rect.y, maxX: try add(rect.x, rect.width), maxY: try add(rect.y, rect.height)))
                }
            }
            try budget.extend(output.vias.count); try budget.charge(output.vias.count)
            for via in output.vias where via.netID == net && (via.lowerLayer == item.layer || via.upperLayer == item.layer) {
                guard let master = via.master else { throw Failure(code: "routing_via_source_invalid", message: "AREA requires exact fixed contacts.") }
                let shapes = try geometry.viaShapes(master: master, x: via.x, y: via.y).filter { Int($0.layer) == item.layer }
                let material = try PhysicalDesignRoutingSpacingObject.compile(Region(layer: Int16(item.layer), polygons: shapes), budget: &budget, retainingMaterialBands: true)
                guard let bands = material.materialBands else { throw Failure(code: "routing_area_geometry_invalid", message: "Contact area facts are unavailable.") }
                try budget.extend(bands.count); try budget.charge(bands.count)
                routed.append(contentsOf: bands)
            }
            for component in components where !rule.accepts(component.areaDBU2) {
                try budget.extend(try multiply(component.bands.count, routed.count))
                var containsRoute = false
                for band in component.bands {
                    for wire in routed {
                        try budget.admit()
                        if min(band.maxX, wire.maxX) > max(band.minX, wire.minX)
                            && min(band.maxY, wire.maxY) > max(band.minY, wire.minY) { containsRoute = true }
                    }
                }
                if containsRoute { try budget.extend(1); try budget.admit(); result.append((index, component, rule.minimumDBU2)) }
            }
        }
        return result
    }

    private static func repairMetalArea(_ output: inout PhysicalDesignSnapshot, occupancy: inout [Occupancy],
        selected: Set<String>, core: PhysicalDesignSnapshot.Rect, geometry: PhysicalDesignProcessGeometry,
        minimumSpacing: Int64, budget: inout PhysicalDesignRoutingWorkBudget) throws {
        guard !geometry.routingMinimumAreas.isEmpty else { return }
        var violations = try areaViolations(occupancy, output: output, geometry: geometry, budget: &budget)
        let ceiling = violations.count
        for _ in 0..<ceiling {
            if violations.isEmpty { return }
            let violation = violations[0], item = occupancy[violation.item]
            guard let net = item.netID, selected.contains(net) else {
                throw Failure(code: "routing_retained_minimum_area_invalid", message: "A deficient unselected routed component cannot be silently changed.")
            }
            var accepted = false
            try budget.extend(output.routes.count); try budget.charge(output.routes.count)
            search: for routeIndex in output.routes.indices where output.routes[routeIndex].netID == net {
                try budget.extend(output.routes[routeIndex].segments.count)
                try budget.charge(output.routes[routeIndex].segments.count)
                for segmentIndex in output.routes[routeIndex].segments.indices {
                    let original = output.routes[routeIndex].segments[segmentIndex]
                    guard original.layer == item.layer, let width = original.widthDBU, let caps = original.endpointExtensions else { continue }
                    let rect = try original.qualifiedFootprint()
                    let x1 = try add(rect.x, rect.width), y1 = try add(rect.y, rect.height)
                    try budget.extend(violation.component.bands.count)
                    var belongs = false
                    for band in violation.component.bands {
                        try budget.admit()
                        if min(x1, band.maxX) > max(rect.x, band.minX) && min(y1, band.maxY) > max(rect.y, band.minY) { belongs = true }
                    }
                    if !belongs { continue }
                    let horizontal = original.y1 == original.y2
                    let forward = horizontal ? original.x1 < original.x2 : original.y1 < original.y2
                    let missing = violation.minimum - violation.component.areaDBU2
                    let extra = missing / UInt64(width) + (missing % UInt64(width) == 0 ? 0 : 1)
                    for begin in [true, false] {
                        try budget.extend(1); try budget.admit()
                        let lower = begin == forward
                        let gap = horizontal
                            ? (lower ? rect.x - violation.component.bounds.minX : violation.component.bounds.maxX - x1)
                            : (lower ? rect.y - violation.component.bounds.minY : violation.component.bounds.maxY - y1)
                        let raw = UInt64(max(0, gap)).addingReportingOverflow(extra)
                        let step = UInt64(geometry.manufacturingGrid.stepDBU ?? 1)
                        let count = raw.partialValue / step + (raw.partialValue % step == 0 ? 0 : 1)
                        let rounded = count.multipliedReportingOverflow(by: step)
                        guard !raw.overflow, !rounded.overflow, let length = Int64(exactly: rounded.partialValue) else { continue }
                        let next = (begin ? caps.beginDBU : caps.endDBU).addingReportingOverflow(length)
                        if next.overflow { continue }
                        var candidate = original
                        candidate.endpointExtensions = .init(beginDBU: begin ? next.partialValue : caps.beginDBU,
                            endDBU: begin ? caps.endDBU : next.partialValue)
                        let footprint: PhysicalDesignSnapshot.Rect
                        do { footprint = try candidate.qualifiedFootprint() }
                        catch PhysicalDesignRouteEndpointExtensions.GeometryError.coordinateOverflow { continue }
                        try geometry.manufacturingGrid.validate(footprint, field: "AREA endpoint repair")
                        let region = try conductor(candidate, width: width)
                        if try !fits(region, core: core) { continue }
                        guard let rule = geometry.routingSpacingRules[Int16(item.layer)] else {
                            throw Failure(code: "routing_layer_semantics_missing", message: "AREA repair requires an exact source spacing rule.")
                        }
                        let spacing = max(minimumSpacing, try rule.spacing(maximumWidth: width, parallelLength: .min))
                        if try !clear(region, layer: item.layer, obstacles: occupancy.filter { $0.blockage || $0.netID != net }, spacing: spacing, rule: rule, budget: &budget) { continue }
                        let trialEntries = try add(occupancy.count, 1)
                        try budget.extend(trialEntries); try budget.charge(trialEntries)
                        var trial = occupancy
                        trial.append(try occupied(layer: item.layer, region: region, netID: net, geometry: geometry, budget: &budget))
                        try coalesceMetal(&trial, geometry: geometry, budget: &budget)
                        do { try replayMetalSpacing(trial, geometry: geometry, minimum: minimumSpacing, budget: &budget) }
                        catch let failure as Failure where failure.code == "routing_final_spacing_invalid" { continue }
                        let candidateEntries = try add(output.routes.count, output.routes[routeIndex].segments.count)
                        try budget.extend(candidateEntries); try budget.charge(candidateEntries)
                        var candidateOutput = output
                        candidateOutput.routes[routeIndex].segments[segmentIndex] = candidate
                        let remaining = try areaViolations(trial, output: candidateOutput, geometry: geometry, budget: &budget)
                        if remaining.count >= violations.count { continue }
                        output = candidateOutput; occupancy = trial; violations = remaining
                        accepted = true
                        break search
                    }
                }
            }
            if !accepted {
                throw Failure(code: "routing_minimum_area_unrepairable", message: "No legal bounded endpoint extension satisfies AREA for net \(net) on layer \(item.layer).")
            }
        }
        guard violations.isEmpty else { throw Failure(code: "routing_area_geometry_invalid", message: "AREA repair failed its strict progress invariant.") }
    }

}
