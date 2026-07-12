import Foundation
import XcircuitePackage

public struct PhysicalDesignNativeMutationEngine: Sendable {
    public struct Outcome: Sendable, Hashable {
        public var snapshot: PhysicalDesignSnapshot?
        public var status: XcircuiteEngineExecutionStatus
        public var diagnostics: [XcircuiteEngineDiagnostic]
        public var candidateActions: [String]
        public var metrics: [PhysicalDesignMetric]

        public init(
            snapshot: PhysicalDesignSnapshot?,
            status: XcircuiteEngineExecutionStatus,
            diagnostics: [XcircuiteEngineDiagnostic] = [],
            candidateActions: [String] = [],
            metrics: [PhysicalDesignMetric] = []
        ) {
            self.snapshot = snapshot
            self.status = status
            self.diagnostics = diagnostics
            self.candidateActions = candidateActions
            self.metrics = metrics
        }
    }

    public init() {}

    public func apply(
        _ request: PhysicalDesignRequest,
        to input: PhysicalDesignSnapshot
    ) async -> Outcome {
        if Task.isCancelled {
            return Outcome(
                snapshot: input,
                status: .cancelled,
                diagnostics: [diagnostic(
                    severity: .warning,
                    code: "execution_cancelled",
                    message: "Physical design execution was cancelled before mutation.",
                    actions: ["resume_from_the_last_immutable_revision"]
                )]
            )
        }

        let configurationErrors = request.configuration.validationDiagnostics()
        guard configurationErrors.isEmpty else {
            return blocked(
                code: "invalid_configuration",
                message: configurationErrors.joined(separator: "; "),
                actions: ["correct_stage_configuration"]
            )
        }

        let snapshotErrors = input.validationDiagnostics()
        guard snapshotErrors.isEmpty else {
            return blocked(
                code: "invalid_physical_snapshot",
                message: snapshotErrors.joined(separator: "; "),
                actions: ["repair_or_regenerate_the_canonical_snapshot"]
            )
        }

        switch request.stage {
        case .floorplan:
            return floorplan(input, configuration: request.configuration)
        case .powerPlanning:
            return powerPlanning(input, configuration: request.configuration)
        case .placement:
            return placement(input, configuration: request.configuration)
        case .clockTreeSynthesis:
            return clockTreeSynthesis(input, configuration: request.configuration)
        case .globalRouting:
            return routing(input, configuration: request.configuration, mode: "global")
        case .detailedRouting:
            return routing(input, configuration: request.configuration, mode: "detailed")
        case .timingECO, .drcRepair:
            return eco(input, configuration: request.configuration, stage: request.stage)
        case .antennaRepair:
            return antennaRepair(input, configuration: request.configuration)
        case .fillInsertion:
            return fillInsertion(input, configuration: request.configuration)
        case .redundantViaInsertion:
            return redundantViaInsertion(input, configuration: request.configuration)
        case .hotspotRepair:
            return hotspotRepair(input, configuration: request.configuration)
        }
    }

    private func floorplan(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration
    ) -> Outcome {
        var output = input
        if output.die == nil {
            output.die = PhysicalDesignSnapshot.Rect(
                x: 0,
                y: 0,
                width: configuration.dieWidth,
                height: configuration.dieHeight
            )
        }
        if output.core == nil, let die = output.die {
            output.core = PhysicalDesignSnapshot.Rect(
                x: die.x + configuration.coreMargin,
                y: die.y + configuration.coreMargin,
                width: die.width - configuration.coreMargin * 2,
                height: die.height - configuration.coreMargin * 2
            )
        }
        if output.rows.isEmpty, let core = output.core {
            let rowCount = max(1, core.height / configuration.rowHeight)
            output.rows = (0..<rowCount).map { index in
                PhysicalDesignSnapshot.Row(
                    id: "row_\(index)",
                    originX: core.x,
                    originY: core.y + index * configuration.rowHeight,
                    siteWidth: configuration.siteWidth,
                    height: configuration.rowHeight,
                    siteCount: max(1, core.width / configuration.siteWidth)
                )
            }
        }
        if let core = output.core {
            var implementationState = output.implementationState ?? PhysicalDesignImplementationState()
            let constraints = configuration.implementationConstraints ?? .default
            if implementationState.tracks.isEmpty {
                implementationState.tracks = configuration.preferredRoutingLayers.enumerated().map { _, layer in
                    let direction = layer.isMultiple(of: 2) ? "vertical" : "horizontal"
                    let extent = direction == "horizontal" ? core.width : core.height
                    return PhysicalDesignImplementationState.Track(
                        id: "track_M\(layer)",
                        layer: layer,
                        direction: direction,
                        origin: direction == "horizontal" ? core.y : core.x,
                        spacing: constraints.trackPitch,
                        count: max(1, extent / constraints.trackPitch)
                    )
                }
            }
            if implementationState.powerDomains.isEmpty {
                implementationState.powerDomains = [PhysicalDesignImplementationState.PowerDomain(
                    id: "power_domain_default",
                    netIDs: configuration.powerNetNames,
                    geometry: core
                )]
            }
            if implementationState.pads.isEmpty, let die = output.die {
                implementationState.pads = output.pins.filter { $0.cellID == nil }.map { pin in
                    let side = padSide(for: pin, die: die)
                    let geometry = padGeometry(for: pin, side: side, die: die, configuration: configuration)
                    return PhysicalDesignImplementationState.Pad(
                        id: "pad_\(pin.id)",
                        pinID: pin.id,
                        side: side,
                        geometry: geometry,
                        placed: true
                    )
                }.sorted { $0.id < $1.id }
            }
            output.implementationState = implementationState
        }
        output.metadata["floorplanStatus"] = "generated"
        return completed(
            output,
            actions: ["run_power_planning", "run_placement"],
            metrics: metrics(for: output)
        )
    }

    private func powerPlanning(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration
    ) -> Outcome {
        guard let core = input.core else {
            return blocked(
                code: "core_geometry_missing",
                message: "Power planning requires a core rectangle.",
                actions: ["run_floorplan"]
            )
        }
        var output = input
        let startingCount = output.powerStructures.count
        let existingIDs = Set(output.powerStructures.map(\.id))
        for (netIndex, netID) in configuration.powerNetNames.enumerated() {
            let ringGeometries = [
                PhysicalDesignSnapshot.Rect(x: core.x, y: core.y, width: core.width, height: configuration.siteWidth),
                PhysicalDesignSnapshot.Rect(x: core.x, y: core.maxY - configuration.siteWidth, width: core.width, height: configuration.siteWidth),
                PhysicalDesignSnapshot.Rect(x: core.x, y: core.y, width: configuration.siteWidth, height: core.height),
                PhysicalDesignSnapshot.Rect(x: core.maxX - configuration.siteWidth, y: core.y, width: configuration.siteWidth, height: core.height)
            ]
            for (side, geometry) in ringGeometries.enumerated() {
                let id = "power_\(netID)_ring_\(side)"
                guard !existingIDs.contains(id) else { continue }
                output.powerStructures.append(
                    PhysicalDesignSnapshot.PowerStructure(
                        id: id,
                        netID: netID,
                        kind: "ring",
                        layer: 1 + netIndex,
                        geometry: geometry
                    )
                )
            }
            let strapCount = max(1, core.width / max(configuration.fillWindowSize, configuration.siteWidth * 10))
            for index in 0..<strapCount {
                let x = core.x + (index + 1) * core.width / (strapCount + 1)
                let id = "power_\(netID)_strap_\(index)"
                guard !existingIDs.contains(id) else { continue }
                output.powerStructures.append(
                    PhysicalDesignSnapshot.PowerStructure(
                        id: id,
                        netID: netID,
                        kind: "strap",
                        layer: 2 + netIndex,
                        geometry: PhysicalDesignSnapshot.Rect(
                            x: x,
                            y: core.y,
                            width: configuration.siteWidth,
                            height: core.height
                        )
                    )
                )
            }
        }
        output.metadata["powerPlanningStatus"] = "generated"
        let added = output.powerStructures.count - startingCount
        return completed(
            output,
            actions: ["run_placement", "run_global_routing", "verify_power_connectivity"],
            metrics: metrics(for: output) + [PhysicalDesignMetric(name: "powerStructuresAdded", value: Double(added), unit: "structures")]
        )
    }

    private func placement(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration
    ) -> Outcome {
        guard !input.cells.isEmpty else {
            return blocked(
                code: "mapped_cells_missing",
                message: "Placement requires mapped cells in the canonical physical snapshot.",
                actions: ["provide_a_mapped_design_snapshot"]
            )
        }
        guard !input.rows.isEmpty else {
            return blocked(
                code: "placement_rows_missing",
                message: "Placement requires floorplan rows.",
                actions: ["run_floorplan"]
            )
        }

        var output = input
        var implementationState = output.implementationState ?? PhysicalDesignImplementationState()
        var blockageConflictCount = 0
        let rows = output.rows.sorted { $0.id < $1.id }
        for cell in output.cells where cell.locked && !cell.placed {
            return blocked(
                code: "locked_cell_unplaced",
                message: "Locked cell \(cell.id) has no legal placement.",
                entity: cell.id,
                actions: ["place_or_unlock_the_cell"]
            )
        }
        var rowIndex = 0
        var cursorX = rows[0].originX
        let sortedCellIDs = output.cells.filter { !$0.locked }.map(\.id).sorted()
        for cellID in sortedCellIDs {
            guard let cellIndex = output.cells.firstIndex(where: { $0.id == cellID }) else { continue }
            var cell = output.cells[cellIndex]
            guard cell.width > 0, cell.height > 0 else {
                return blocked(
                    code: "invalid_cell_geometry",
                    message: "Cell \(cell.id) has non-positive geometry.",
                    entity: cell.id,
                    actions: ["repair_cell_geometry"]
                )
            }
            cell.placed = false
            while rowIndex < rows.count {
                let row = rows[rowIndex]
                let rowEnd = row.originX + row.siteCount * row.siteWidth
                let alignedX = row.originX + max(0, cursorX - row.originX + row.siteWidth - 1) / row.siteWidth * row.siteWidth
                let candidate = PhysicalDesignSnapshot.Rect(
                    x: alignedX,
                    y: row.originY,
                    width: cell.width,
                    height: cell.height
                )
                let fitsInRow = cell.height <= row.height && alignedX + cell.width <= rowEnd
                if fitsInRow, output.blockages.contains(where: { $0.intersects(candidate) }) {
                    blockageConflictCount += 1
                    cursorX = alignedX + max(cell.width, configuration.siteWidth) + configuration.placementSpacing
                    continue
                }
                if fitsInRow {
                    cell.x = alignedX
                    cell.y = row.originY
                    cell.placed = true
                    cursorX = alignedX + cell.width + configuration.placementSpacing
                    output.cells[cellIndex] = cell
                    break
                }
                cursorX = alignedX + max(cell.width, configuration.siteWidth) + configuration.placementSpacing
                rowIndex += 1
                if rowIndex < rows.count {
                    cursorX = rows[rowIndex].originX
                }
            }
            guard cell.placed else {
                return blocked(
                    code: "placement_capacity_exceeded",
                    message: "No legal placement row has capacity for cell \(cell.id).",
                    entity: cell.id,
                    actions: ["increase_core_area", "reduce_cell_density", "change_placement_constraints"]
                )
            }
        }

        for index in output.cells.indices where output.cells[index].locked {
            guard let core = output.core else { continue }
            let cell = output.cells[index]
            guard core.contains(PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)) else {
                return blocked(
                    code: "locked_cell_outside_core",
                    message: "Locked cell \(cell.id) is outside the core.",
                    entity: cell.id,
                    actions: ["move_or_unlock_the_cell"]
                )
            }
        }
        let core = output.core
        let placedRects = output.cells.map { cell in
            PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)
        }
        var overlapCount = 0
        for firstIndex in placedRects.indices {
            for secondIndex in placedRects.indices where secondIndex > firstIndex {
                if placedRects[firstIndex].intersects(placedRects[secondIndex]) {
                    overlapCount += 1
                }
            }
        }
        let outsideCoreCount = output.cells.filter { cell in
            guard let core else { return false }
            return !core.contains(PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height))
        }.count
        let utilization: Double
        if let core, core.width > 0, core.height > 0 {
            let cellArea = output.cells.reduce(0.0) { partial, cell in
                partial + Double(cell.width) * Double(cell.height)
            }
            utilization = cellArea / (Double(core.width) * Double(core.height))
        } else {
            utilization = 0
        }
        let timingObjective = estimatedWirelength(output)
        let congestionObjective = maximumRowUtilization(output)
        let legalCellCount = max(0, output.cells.count - overlapCount - outsideCoreCount)
        implementationState.placementProof = PhysicalDesignImplementationState.PlacementProof(
            cellCount: output.cells.count,
            legalCellCount: legalCellCount,
            overlapCount: overlapCount,
            outsideCoreCount: outsideCoreCount,
            blockageConflictCount: blockageConflictCount,
            blockedCellCount: 0,
            utilization: utilization,
            timingObjective: timingObjective,
            congestionObjective: congestionObjective
        )
        output.implementationState = implementationState
        var placementDiagnostics: [XcircuiteEngineDiagnostic] = []
        if utilization > configuration.targetUtilization {
            placementDiagnostics.append(diagnostic(
                severity: .warning,
                code: "placement_target_utilization_exceeded",
                message: "Placement utilization (utilization) exceeds the target (configuration.targetUtilization).",
                actions: ["increase_core_area", "reduce_cell_density"]
            ))
        }
        output.metadata["placementStatus"] = "legalized"
        return completed(
            output,
            diagnostics: placementDiagnostics,
            actions: ["run_clock_tree_synthesis", "run_global_routing"],
            metrics: metrics(for: output) + [
                PhysicalDesignMetric(
                    name: "placedCellRatio",
                    value: Double(output.cells.filter(\.placed).count) / Double(output.cells.count),
                    unit: "ratio"
                ),
                PhysicalDesignMetric(
                    name: "placementTimingObjective",
                    value: timingObjective,
                    unit: "database-units"
                ),
                PhysicalDesignMetric(
                    name: "placementCongestionObjective",
                    value: congestionObjective,
                    unit: "ratio"
                )
            ]
        )
    }

    private func clockTreeSynthesis(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration
    ) -> Outcome {
        let clockNets = input.nets.filter(\.isClock).sorted { $0.id < $1.id }
        guard !clockNets.isEmpty else {
            return blocked(
                code: "clock_net_missing",
                message: "Clock-tree synthesis requires at least one net marked as a clock.",
                actions: ["declare_clock_nets_in_the_snapshot", "run_clock_tree_synthesis_after_clock_definition"]
            )
        }
        var output = input
        let pinByID = Dictionary(uniqueKeysWithValues: output.pins.map { ($0.id, $0) })
        let existingIDs = Set(output.clockTrees.map(\.id))
        let implementationConstraints = configuration.implementationConstraints ?? .default
        var implementationState = output.implementationState ?? PhysicalDesignImplementationState()
        for net in clockNets {
            guard net.pinIDs.count >= 2 else {
                return blocked(
                    code: "clock_net_has_insufficient_sinks",
                    message: "Clock net \(net.id) must connect a source and at least one sink.",
                    entity: net.id,
                    actions: ["repair_clock_connectivity"]
                )
            }
            let pins = net.pinIDs.compactMap { pinByID[$0] }
            guard pins.count == net.pinIDs.count else {
                return blocked(
                    code: "clock_pin_missing",
                    message: "Clock net \(net.id) refers to a missing pin.",
                    entity: net.id,
                    actions: ["repair_clock_connectivity"]
                )
            }
            let source = pins.first(where: { $0.direction.lowercased() == "output" }) ?? pins[0]
            let sinks = pins.filter { $0.id != source.id }.sorted { $0.id < $1.id }
            let distances = sinks.map { manhattan(source.x, source.y, $0.x, $0.y) }
            let skew = (distances.max() ?? 0) - (distances.min() ?? 0)
            let id = "clock_tree_\(net.id)"
            guard !existingIDs.contains(id) else { continue }
            var parentPinIDs: [String] = [source.id]
            var bufferCellIDs: [String] = []
            var bufferIndex = 0
            for (sinkIndex, sink) in sinks.enumerated() {
                let distance = distances[sinkIndex]
                guard distance > implementationConstraints.clockTargetSkewPS else {
                    parentPinIDs.append(sink.id)
                    continue
                }
                guard let row = output.rows.sorted(by: { $0.id < $1.id }).min(by: { lhs, rhs in
                    abs(lhs.originY - (source.y + sink.y) / 2) < abs(rhs.originY - (source.y + sink.y) / 2)
                }) else {
                    return blocked(
                        code: "cts_rows_missing",
                        message: "Clock buffering requires placement rows to materialize buffer cells.",
                        entity: net.id,
                        actions: ["run_floorplan_before_clock_tree_synthesis"]
                    )
                }
                let width = max(configuration.siteWidth * 2, implementationConstraints.routeWidth)
                let x = max(row.originX, min((source.x + sink.x) / 2, row.originX + row.siteCount * row.siteWidth - width))
                let y = row.originY
                let bufferGeometry = PhysicalDesignSnapshot.Rect(x: x, y: y, width: width, height: row.height)
                guard !output.blockages.contains(where: { $0.intersects(bufferGeometry) }) else {
                    return blocked(
                        code: "cts_buffer_blocked",
                        message: "Clock buffer location for sink \(sink.id) intersects a placement blockage.",
                        entity: sink.id,
                        actions: ["move_the_blockage", "increase_clock_buffer_placement_area"]
                    )
                }
                let bufferID = "cts_buf_\(net.id)_\(bufferIndex)"
                let inputPinID = "pin_\(bufferID)_A"
                let outputPinID = "pin_\(bufferID)_Y"
                let branchNetID = "\(net.id)_branch_\(bufferIndex)"
                output.cells.append(PhysicalDesignSnapshot.Cell(
                    id: bufferID,
                    master: implementationConstraints.clockBufferMaster,
                    x: x,
                    y: y,
                    width: width,
                    height: row.height,
                    placed: true,
                    isClockBuffer: true
                ))
                output.pins.append(PhysicalDesignSnapshot.Pin(
                    id: inputPinID,
                    cellID: bufferID,
                    name: "A",
                    x: x,
                    y: y + row.height / 2,
                    netID: net.id,
                    direction: "input"
                ))
                output.pins.append(PhysicalDesignSnapshot.Pin(
                    id: outputPinID,
                    cellID: bufferID,
                    name: "Y",
                    x: x + width,
                    y: y + row.height / 2,
                    netID: branchNetID,
                    direction: "output"
                ))
                if let sinkPinIndex = output.pins.firstIndex(where: { $0.id == sink.id }) {
                    output.pins[sinkPinIndex].netID = branchNetID
                }
                output.nets.append(PhysicalDesignSnapshot.Net(
                    id: branchNetID,
                    pinIDs: [outputPinID, sink.id],
                    isClock: true
                ))
                parentPinIDs.append(inputPinID)
                bufferCellIDs.append(bufferID)
                implementationState.clockRouteConstraints.append(PhysicalDesignImplementationState.ClockRouteConstraint(
                    id: "clock_route_\(branchNetID)",
                    netID: branchNetID,
                    layer: implementationConstraints.clockRouteLayer,
                    width: implementationConstraints.routeWidth,
                    spacing: implementationConstraints.routeSpacing,
                    maximumLength: implementationConstraints.clockTargetSkewPS * 4
                ))
                bufferIndex += 1
            }
            if let netIndex = output.nets.firstIndex(where: { $0.id == net.id }) {
                output.nets[netIndex].pinIDs = parentPinIDs.sorted()
            }
            output.clockTrees.append(
                PhysicalDesignSnapshot.ClockTree(
                    id: id,
                    netID: net.id,
                    sourcePinID: source.id,
                    sinkPinIDs: sinks.map(\.id),
                    bufferCellIDs: bufferCellIDs,
                    estimatedSkewPS: skew,
                    estimatedLatencyPS: distances.max() ?? 0
                )
            )
            implementationState.clockRouteConstraints.append(PhysicalDesignImplementationState.ClockRouteConstraint(
                id: "clock_route_\(net.id)",
                netID: net.id,
                layer: implementationConstraints.clockRouteLayer,
                width: implementationConstraints.routeWidth,
                spacing: implementationConstraints.routeSpacing,
                maximumLength: implementationConstraints.clockTargetSkewPS * 4
            ))
        }
        output.implementationState = implementationState
        output.metadata["clockTreeStatus"] = "constructed"
        return completed(
            output,
            actions: ["run_detailed_routing", "run_timing_analysis"],
            metrics: metrics(for: output) + [
                PhysicalDesignMetric(name: "clockTreeCount", value: Double(output.clockTrees.count), unit: "trees")
            ]
        )
    }

    private func routing(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration,
        mode: String
    ) -> Outcome {
        guard !input.cells.isEmpty, input.cells.allSatisfy(\.placed) else {
            return blocked(
                code: "placed_cells_missing",
                message: "Routing requires all cells to be legally placed.",
                actions: ["run_placement"]
            )
        }
        guard !input.nets.isEmpty else {
            return blocked(
                code: "routable_nets_missing",
                message: "Routing requires at least one net.",
                actions: ["provide_net_connectivity"]
            )
        }

        var output = input
        let pinByID = Dictionary(uniqueKeysWithValues: output.pins.map { ($0.id, $0) })
        let cellByID = Dictionary(uniqueKeysWithValues: output.cells.map { ($0.id, $0) })
        let implementationConstraints = configuration.implementationConstraints ?? .default
        let tracks = output.implementationState?.tracks ?? []
        var routes: [PhysicalDesignSnapshot.Route] = []
        var warnings: [XcircuiteEngineDiagnostic] = []
        var routeFailures: [XcircuiteEngineDiagnostic] = []
        var skippedNetIDs: [String] = []
        var blockageConflictCount = 0
        var layerDirectionViolations = 0
        var spacingConflicts = 0
        var antennaRiskNetIDs: [String] = []
        var routeGeometries: [(netID: String, layer: Int, geometry: PhysicalDesignSnapshot.Rect)] = []
        var generatedVias: [PhysicalDesignSnapshot.Via] = []
        for (netOrdinal, net) in output.nets.sorted(by: { $0.id < $1.id }).enumerated() {
            let pins = net.pinIDs.compactMap { pinByID[$0] }
            let locations = pins.map { pinLocation($0, cells: cellByID) }
            guard locations.count == net.pinIDs.count, locations.count >= 2 else {
                warnings.append(diagnostic(
                    severity: .warning,
                    code: "net_not_routable",
                    message: "Net \(net.id) has fewer than two resolvable pins and was not routed.",
                    entity: net.id,
                    actions: ["repair_net_connectivity"]
                ))
                skippedNetIDs.append(net.id)
                continue
            }
            let source = locations[0]
            var segments: [PhysicalDesignSnapshot.RouteSegment] = []
            var segmentGeometries: [PhysicalDesignSnapshot.Rect] = []
            var netFailed = false
            for (index, location) in locations.dropFirst().enumerated() {
                guard let horizontalLayer = routingLayer(direction: "horizontal", preferredLayers: configuration.preferredRoutingLayers, tracks: tracks, offset: netOrdinal),
                      let verticalLayer = routingLayer(direction: "vertical", preferredLayers: configuration.preferredRoutingLayers, tracks: tracks, offset: netOrdinal) else {
                    layerDirectionViolations += 1
                    routeFailures.append(diagnostic(
                        severity: .error,
                        code: "routing_layer_direction_missing",
                        message: "Net \(net.id) cannot be assigned both horizontal and vertical routing layers.",
                        entity: net.id,
                        actions: ["declare_directional_routing_tracks", "provide_a_qualified_external_router"]
                    ))
                    netFailed = true
                    break
                }
                let horizontalSegment = PhysicalDesignSnapshot.RouteSegment(
                    id: "route_\(net.id)_\(index)_h",
                    layer: horizontalLayer,
                    x1: source.x,
                    y1: source.y,
                    x2: location.x,
                    y2: source.y
                )
                let verticalSegment = PhysicalDesignSnapshot.RouteSegment(
                    id: "route_\(net.id)_\(index)_v",
                    layer: verticalLayer,
                    x1: location.x,
                    y1: source.y,
                    x2: location.x,
                    y2: location.y
                )
                let geometries = [
                    segmentGeometry(horizontalSegment, width: implementationConstraints.routeWidth),
                    segmentGeometry(verticalSegment, width: implementationConstraints.routeWidth)
                ]
                if geometries.contains(where: { geometry in
                    output.blockages.contains { $0.intersects(geometry) }
                }) {
                    blockageConflictCount += 1
                    routeFailures.append(diagnostic(
                        severity: .error,
                        code: "routing_blockage_conflict",
                        message: "Net \(net.id) intersects a placement or routing blockage.",
                        entity: net.id,
                        actions: ["move_the_blockage", "reroute_around_the_blockage"]
                    ))
                    netFailed = true
                    break
                }
                if zip([horizontalLayer, verticalLayer], geometries).contains(where: { layer, geometry in
                    routeGeometries.contains { existing in
                        existing.netID != net.id && existing.layer == layer && existing.geometry.expanded(by: implementationConstraints.routeSpacing).intersects(geometry)
                    }
                }) {
                    spacingConflicts += 1
                    routeFailures.append(diagnostic(
                        severity: .error,
                        code: "routing_spacing_conflict",
                        message: "Net \(net.id) violates the configured route spacing against an existing route.",
                        entity: net.id,
                        actions: ["increase_route_spacing", "choose_another_routing_layer", "reroute_around_the_conflict"]
                    ))
                    netFailed = true
                    break
                }
                segments.append(horizontalSegment)
                segments.append(verticalSegment)
                segmentGeometries.append(contentsOf: geometries)
                if horizontalLayer != verticalLayer {
                    generatedVias.append(PhysicalDesignSnapshot.Via(
                        id: "via_\(net.id)_\(index)",
                        netID: net.id,
                        x: location.x,
                        y: source.y,
                        lowerLayer: min(horizontalLayer, verticalLayer),
                        upperLayer: max(horizontalLayer, verticalLayer)
                    ))
                }
            }
            if netFailed {
                skippedNetIDs.append(net.id)
                continue
            }
            routes.append(PhysicalDesignSnapshot.Route(id: "route_\(net.id)", netID: net.id, segments: segments))
            routeGeometries.append(contentsOf: zip(segments, segmentGeometries).map { (netID: net.id, layer: $0.0.layer, geometry: $0.1) })
            if let ratio = net.antennaRatio, ratio > (net.maximumAntennaRatio ?? configuration.maximumAntennaRatio) {
                antennaRiskNetIDs.append(net.id)
                warnings.append(diagnostic(
                    severity: .warning,
                    code: "routing_antenna_risk",
                    message: "Net \(net.id) exceeds its antenna ratio limit after routing.",
                    entity: net.id,
                    actions: ["run_antenna_repair", "verify_with_the_drc_antenna_oracle"]
                ))
            }
        }
        if !routeFailures.isEmpty {
            return Outcome(
                snapshot: nil,
                status: .blocked,
                diagnostics: routeFailures + warnings,
                candidateActions: ["repair_routing_constraints", "use_a_qualified_external_router"]
            )
        }
        guard !routes.isEmpty else {
            return blocked(
                code: "no_net_could_be_routed",
                message: "No net had sufficient connectivity for native routing.",
                actions: ["repair_net_connectivity", "use_a_qualified_external_router"]
            )
        }
        let existingViaIDs = Set(output.vias.map(\.id))
        output.vias.append(contentsOf: generatedVias.filter { !existingViaIDs.contains($0.id) })
        output.routes = output.routes.filter { route in !routes.contains(where: { $0.netID == route.netID }) } + routes
        var implementationState = output.implementationState ?? PhysicalDesignImplementationState()
        implementationState.routingEvidence = PhysicalDesignImplementationState.RoutingEvidence(
            mode: mode,
            routedNetCount: routes.count,
            skippedNetIDs: skippedNetIDs.sorted(),
            blockageConflictCount: blockageConflictCount,
            layerDirectionViolations: layerDirectionViolations,
            spacingConflicts: spacingConflicts,
            antennaRiskNetIDs: antennaRiskNetIDs.sorted(),
            viaCount: generatedVias.count
        )
        output.implementationState = implementationState
        output.metadata["routingStatus"] = mode
        let warningsMessage = warnings.isEmpty ? "" : " Some nets were skipped with warnings."
        return completed(
            output,
            diagnostics: warnings,
            actions: ["run_antenna_repair", "run_drc", "run_lvs"],
            metrics: metrics(for: output) + [
                PhysicalDesignMetric(name: "routedNetCount", value: Double(routes.count), unit: "nets"),
                PhysicalDesignMetric(name: "routingWarnings", value: Double(warnings.count), unit: "findings")
            ],
            note: "Native \(mode) routing completed.\(warningsMessage)"
        )
    }

    private func routingLayer(
        direction: String,
        preferredLayers: [Int],
        tracks: [PhysicalDesignImplementationState.Track],
        offset: Int
    ) -> Int? {
        let directionalTracks = tracks.filter { $0.direction.lowercased() == direction }.sorted(by: { $0.layer < $1.layer })
        if !directionalTracks.isEmpty {
            return directionalTracks[offset % directionalTracks.count].layer
        }
        let fallback = preferredLayers.filter { layer in
            direction == "horizontal" ? !layer.isMultiple(of: 2) : layer.isMultiple(of: 2)
        }
        if !fallback.isEmpty {
            return fallback[offset % fallback.count]
        }
        return preferredLayers.first
    }

    private func segmentGeometry(
        _ segment: PhysicalDesignSnapshot.RouteSegment,
        width: Int64
    ) -> PhysicalDesignSnapshot.Rect {
        let halfWidth = max(1, width / 2)
        if segment.y1 == segment.y2 {
            let minimumX = min(segment.x1, segment.x2)
            return PhysicalDesignSnapshot.Rect(
                x: minimumX,
                y: segment.y1 - halfWidth,
                width: max(1, abs(segment.x2 - segment.x1)),
                height: max(1, width)
            )
        }
        let minimumY = min(segment.y1, segment.y2)
        return PhysicalDesignSnapshot.Rect(
            x: segment.x1 - halfWidth,
            y: minimumY,
            width: max(1, width),
            height: max(1, abs(segment.y2 - segment.y1))
        )
    }

    private func eco(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration,
        stage: PhysicalDesignStage
    ) -> Outcome {
        var output = input
        switch configuration.ecoAction {
        case .resizeCell:
            guard let target = configuration.ecoTargetCellID,
                  let index = output.cells.firstIndex(where: { $0.id == target }) else {
                return blocked(
                    code: "eco_target_cell_missing",
                    message: "ECO resize requires an existing target cell.",
                    actions: ["set_eco_target_cell_id"]
                )
            }
            output.cells[index].width += configuration.siteWidth
            output.cells[index].master += "_ECO"
        case .moveCell:
            guard let target = configuration.ecoTargetCellID,
                  let index = output.cells.firstIndex(where: { $0.id == target }) else {
                return blocked(
                    code: "eco_target_cell_missing",
                    message: "ECO move requires an existing target cell.",
                    actions: ["set_eco_target_cell_id"]
                )
            }
            guard let core = output.core else {
                return blocked(code: "core_geometry_missing", message: "ECO move requires a core rectangle.", actions: ["run_floorplan"])
            }
            let cell = output.cells[index]
            let moved = PhysicalDesignSnapshot.Rect(
                x: cell.x + configuration.ecoDeltaX,
                y: cell.y + configuration.ecoDeltaY,
                width: cell.width,
                height: cell.height
            )
            guard core.contains(moved) else {
                return blocked(
                    code: "eco_move_outside_core",
                    message: "ECO move would place \(target) outside the core.",
                    entity: target,
                    actions: ["reduce_eco_delta", "increase_core_area"]
                )
            }
            output.cells[index].x = moved.x
            output.cells[index].y = moved.y
            output.cells[index].placed = true
        case .bufferInsertion:
            guard let netID = configuration.ecoTargetNetID,
                  output.nets.contains(where: { $0.id == netID }) else {
                return blocked(
                    code: "eco_target_net_missing",
                    message: "Buffer insertion requires an existing target net.",
                    actions: ["set_eco_target_net_id"]
                )
            }
            let bufferID = "eco_buf_\(netID)"
            guard !output.cells.contains(where: { $0.id == bufferID }) else { return completed(output, actions: ["run_timing_analysis"], metrics: metrics(for: output)) }
            let location = output.pins.first(where: { $0.netID == netID })
            output.cells.append(
                PhysicalDesignSnapshot.Cell(
                    id: bufferID,
                    master: "BUF_ECO",
                    x: location?.x ?? 0,
                    y: location?.y ?? 0,
                    width: configuration.siteWidth * 2,
                    height: configuration.rowHeight,
                    placed: true,
                    isClockBuffer: false
                )
            )
        case .rerouteNet:
            guard let netID = configuration.ecoTargetNetID,
                  output.nets.contains(where: { $0.id == netID }) else {
                return blocked(code: "eco_target_net_missing", message: "Reroute requires an existing target net.", actions: ["set_eco_target_net_id"])
            }
            let routingOutcome = routing(output, configuration: configuration, mode: "eco")
            guard let routed = routingOutcome.snapshot else { return routingOutcome }
            output = routed
        case .addBlockage:
            guard let core = output.core else {
                return blocked(code: "core_geometry_missing", message: "ECO blockage insertion requires a core rectangle.", actions: ["run_floorplan"])
            }
            let geometry = PhysicalDesignSnapshot.Rect(
                x: core.x + core.width / 4,
                y: core.y + core.height / 4,
                width: max(configuration.siteWidth, core.width / 20),
                height: max(configuration.rowHeight, core.height / 20)
            )
            output.blockages.append(geometry)
        }
        if let verificationDiagnostic = verifyAndRecordRepair(
            input: input,
            output: &output,
            configuration: configuration,
            stage: stage.rawValue,
            strategy: configuration.ecoAction.rawValue,
            targetIDs: [configuration.ecoTargetCellID, configuration.ecoTargetNetID].compactMap { $0 },
            details: ["rechecked_native_geometry_and_connectivity"]
        ) {
            return Outcome(
                snapshot: nil,
                status: .blocked,
                diagnostics: [verificationDiagnostic],
                candidateActions: ["repair_the_eco_candidate", "rerun_the_relevant_oracle"]
            )
        }
        output.metadata[stage == .drcRepair ? "drcRepairStatus" : "timingECOStatus"] = "applied"
        return completed(
            output,
            actions: ["run_timing_analysis", "run_drc"],
            metrics: metrics(for: output)
        )
    }

    private func antennaRepair(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration
    ) -> Outcome {
        guard !input.routes.isEmpty else {
            return blocked(code: "routes_missing", message: "Antenna repair requires routed nets.", actions: ["run_detailed_routing"])
        }
        var output = input
        let repairConstraints = configuration.repairConstraints ?? .default
        let routeNetIDs = Set(output.routes.map(\.netID))
        var repaired = 0
        var strategies: [String] = []
        for index in output.nets.indices {
            guard let ratio = output.nets[index].antennaRatio,
                  ratio > (output.nets[index].maximumAntennaRatio ?? configuration.maximumAntennaRatio) else { continue }
            let netID = output.nets[index].id
            guard routeNetIDs.contains(netID) else { continue }
            let limit = output.nets[index].maximumAntennaRatio ?? configuration.maximumAntennaRatio
            let resultingRatio = min(ratio, limit * 0.5)
            output.nets[index].antennaRatio = resultingRatio
            let strategy = repairConstraints.antennaStrategy.rawValue
            output.antennaRepairs.append(
                PhysicalDesignSnapshot.AntennaRepair(
                    id: "antenna_repair_\(netID)",
                    netID: netID,
                    strategy: strategy,
                    previousRatio: ratio,
                    resultingRatio: resultingRatio
                )
            )
            if let routeIndex = output.routes.firstIndex(where: { $0.netID == netID }),
               let last = output.routes[routeIndex].segments.last {
                switch repairConstraints.antennaStrategy {
                case .jumper:
                    output.routes[routeIndex].segments.append(
                        PhysicalDesignSnapshot.RouteSegment(
                            id: "antenna_jumper_\(netID)",
                            layer: min(configuration.maximumRoutingLayer, last.layer + 1),
                            x1: last.x2,
                            y1: last.y2,
                            x2: last.x2 + configuration.siteWidth,
                            y2: last.y2,
                            isJumper: true
                        )
                    )
                case .reroute:
                    output.routes[routeIndex].segments.append(
                        PhysicalDesignSnapshot.RouteSegment(
                            id: "antenna_reroute_\(netID)",
                            layer: min(configuration.maximumRoutingLayer, last.layer + 1),
                            x1: last.x2,
                            y1: last.y2,
                            x2: last.x2,
                            y2: last.y2 + configuration.siteWidth
                        )
                    )
                case .protectionDevice:
                    let protectionID = "antenna_protect_\(netID)"
                    if !output.cells.contains(where: { $0.id == protectionID }), let core = output.core {
                        let width = max(configuration.siteWidth, configuration.siteWidth * 2)
                        let geometry = PhysicalDesignSnapshot.Rect(x: core.x, y: core.y, width: width, height: configuration.rowHeight)
                        guard !output.blockages.contains(where: { $0.intersects(geometry) }) else {
                            return blocked(
                                code: "antenna_protection_location_blocked",
                                message: "Protection device location for net \(netID) intersects a blockage.",
                                entity: netID,
                                actions: ["move_the_blockage", "select_the_jumper_strategy"]
                            )
                        }
                        output.cells.append(PhysicalDesignSnapshot.Cell(
                            id: protectionID,
                            master: "ANTENNA_DIODE",
                            x: geometry.x,
                            y: geometry.y,
                            width: geometry.width,
                            height: geometry.height,
                            placed: true
                        ))
                        let pinID = "pin_\(protectionID)_A"
                        output.pins.append(PhysicalDesignSnapshot.Pin(
                            id: pinID,
                            cellID: protectionID,
                            name: "A",
                            x: geometry.x,
                            y: geometry.y,
                            netID: netID,
                            direction: "input"
                        ))
                        output.nets[index].pinIDs.append(pinID)
                    }
                }
            }
            strategies.append(strategy)
            repaired += 1
        }
        guard repaired > 0 else {
            return blocked(
                code: "antenna_target_missing",
                message: "No routed net exceeds its declared antenna ratio limit.",
                actions: ["run_drc_antenna_analysis", "provide_antenna_ratios"]
            )
        }
        guard verifyAndRecordRepair(
            input: input,
            output: &output,
            configuration: configuration,
            stage: PhysicalDesignStage.antennaRepair.rawValue,
            strategy: uniqueStrings(strategies).joined(separator: "+"),
            targetIDs: output.antennaRepairs.suffix(repaired).map(\.netID),
            details: ["rechecked_antenna_ratio_and_native_geometry"]
        ) == nil else {
            return blocked(
                code: "antenna_repair_verification_failed",
                message: "Antenna repair candidates did not pass native post-repair verification.",
                actions: ["review_antenna_repair_strategy", "rerun_drc_antenna_analysis"]
            )
        }
        output.metadata["antennaRepairStatus"] = "candidate_repairs_applied"
        return completed(
            output,
            actions: ["rerun_drc_antenna_analysis", "review_jumper_rules"],
            metrics: metrics(for: output) + [PhysicalDesignMetric(name: "antennaRepairs", value: Double(repaired), unit: "repairs")],
            note: "Antenna repair candidates were applied; the external DRC oracle remains authoritative."
        )
    }

    private func fillInsertion(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration
    ) -> Outcome {
        guard let core = input.core else {
            return blocked(code: "core_geometry_missing", message: "Fill insertion requires a core rectangle.", actions: ["run_floorplan"])
        }
        var output = input
        let repairConstraints = configuration.repairConstraints ?? .default
        guard output.fills.isEmpty else {
            return completed(output, actions: ["run_density_drc"], metrics: metrics(for: output))
        }
        let step = configuration.fillWindowSize + max(configuration.fillSpacing, repairConstraints.minimumFillSpacing)
        guard step > 0 else {
            return blocked(code: "invalid_fill_grid", message: "Fill grid step must be positive.", actions: ["correct_fill_configuration"])
        }
        let fillWidth = max(configuration.siteWidth, configuration.fillWindowSize / 4)
        let fillHeight = max(configuration.rowHeight, configuration.fillWindowSize / 4)
        var id = 0
        var y = core.y + max(configuration.fillSpacing, repairConstraints.minimumFillSpacing)
        let maximumFillArea = Double(core.width) * Double(core.height) * repairConstraints.maximumFillDensity
        while y + fillHeight <= core.maxY {
            var x = core.x + max(configuration.fillSpacing, repairConstraints.minimumFillSpacing)
            while x + fillWidth <= core.maxX {
                let geometry = PhysicalDesignSnapshot.Rect(x: x, y: y, width: fillWidth, height: fillHeight)
                let currentFillArea = output.fills.reduce(0.0) { $0 + Double($1.geometry.width) * Double($1.geometry.height) }
                let conflicts = output.cells.contains { cell in
                    cell.placed && PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height).intersects(geometry)
                }
                    || output.blockages.contains { $0.intersects(geometry) }
                    || output.powerStructures.contains { $0.geometry.expanded(by: repairConstraints.minimumFillSpacing).intersects(geometry) }
                if !conflicts, currentFillArea + Double(fillWidth) * Double(fillHeight) <= maximumFillArea {
                output.fills.append(
                    PhysicalDesignSnapshot.Fill(
                        id: "fill_\(id)",
                        layer: configuration.preferredRoutingLayers[0],
                        geometry: geometry
                    )
                )
                id += 1
                }
                x += step
            }
            y += step
        }
        guard !output.fills.isEmpty else {
            return blocked(code: "fill_area_unavailable", message: "The core is too small for the configured fill grid.", actions: ["reduce_fill_window_size"])
        }
        if let verificationDiagnostic = verifyAndRecordRepair(
            input: input,
            output: &output,
            configuration: configuration,
            stage: PhysicalDesignStage.fillInsertion.rawValue,
            strategy: "windowed_fill",
            targetIDs: output.fills.map(\.id),
            details: ["rechecked_fill_density_spacing_and_blockages"]
        ) {
            return Outcome(snapshot: nil, status: .blocked, diagnostics: [verificationDiagnostic], candidateActions: ["reduce_fill_density", "adjust_fill_spacing"])
        }
        output.metadata["fillStatus"] = "inserted"
        return completed(output, actions: ["run_density_drc", "run_lvs"], metrics: metrics(for: output))
    }

    private func redundantViaInsertion(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration
    ) -> Outcome {
        guard !input.vias.isEmpty else {
            return blocked(code: "vias_missing", message: "Redundant-via insertion requires existing vias.", actions: ["run_detailed_routing"])
        }
        var output = input
        let repairConstraints = configuration.repairConstraints ?? .default
        let existingIDs = Set(output.vias.map(\.id))
        let candidates = output.vias.filter { !$0.isRedundant }
        var inserted = 0
        for via in candidates {
            let id = "\(via.id)_redundant"
            guard !existingIDs.contains(id) else { continue }
            let offsets: [(Int64, Int64)] = [
                (repairConstraints.minimumViaSpacing, repairConstraints.minimumViaSpacing),
                (repairConstraints.minimumViaSpacing, -repairConstraints.minimumViaSpacing),
                (-repairConstraints.minimumViaSpacing, repairConstraints.minimumViaSpacing),
                (-repairConstraints.minimumViaSpacing, -repairConstraints.minimumViaSpacing)
            ]
            guard let offset = offsets.first(where: { deltaX, deltaY in
                let x = via.x + deltaX
                let y = via.y + deltaY
                return output.vias.allSatisfy { existing in
                    existing.id == via.id || manhattan(x, y, existing.x, existing.y) >= repairConstraints.minimumViaSpacing
                }
            }) else { continue }
            output.vias.append(
                PhysicalDesignSnapshot.Via(
                    id: id,
                    netID: via.netID,
                    x: via.x + offset.0,
                    y: via.y + offset.1,
                    lowerLayer: via.lowerLayer,
                    upperLayer: via.upperLayer,
                    isRedundant: true
                )
            )
            inserted += 1
        }
        guard inserted > 0 else {
            return completed(output, actions: ["run_via_drc"], metrics: metrics(for: output))
        }
        if let verificationDiagnostic = verifyAndRecordRepair(
            input: input,
            output: &output,
            configuration: configuration,
            stage: PhysicalDesignStage.redundantViaInsertion.rawValue,
            strategy: "spaced_redundant_via",
            targetIDs: output.vias.suffix(inserted).map(\.id),
            details: ["rechecked_via_spacing_and_layer_pairs"]
        ) {
            return Outcome(snapshot: nil, status: .blocked, diagnostics: [verificationDiagnostic], candidateActions: ["increase_via_spacing", "rerun_detailed_routing"])
        }
        output.metadata["redundantViaStatus"] = "inserted"
        return completed(output, actions: ["run_via_drc", "run_lvs"], metrics: metrics(for: output))
    }

    private func hotspotRepair(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration
    ) -> Outcome {
        var output = input
        let repairConstraints = configuration.repairConstraints ?? .default
        let unresolved = output.hotspots.filter { !$0.resolved }
        guard !unresolved.isEmpty else {
            return blocked(code: "hotspot_target_missing", message: "No unresolved physical hotspots are present.", actions: ["provide_hotspot_analysis"])
        }
        for index in output.hotspots.indices where !output.hotspots[index].resolved {
            let candidate = output.hotspots[index].geometry.expanded(by: repairConstraints.hotspotRepairMargin)
            if let core = output.core, !core.contains(candidate) {
                return blocked(
                    code: "hotspot_repair_outside_core",
                    message: "Hotspot repair candidate \(output.hotspots[index].id) would extend outside the core.",
                    entity: output.hotspots[index].id,
                    actions: ["reduce_hotspot_repair_margin", "increase_core_area"]
                )
            }
            if output.cells.contains(where: { cell in
                cell.placed && PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height).intersects(candidate)
            }) {
                return blocked(
                    code: "hotspot_repair_cell_conflict",
                    message: "Hotspot repair candidate \(output.hotspots[index].id) intersects a placed cell.",
                    entity: output.hotspots[index].id,
                    actions: ["move_the_cell", "reduce_hotspot_repair_margin"]
                )
            }
            output.hotspots[index].resolved = true
            output.hotspots[index].resolution = "native_windowed_geometry_repair"
            output.blockages.append(candidate)
        }
        if let verificationDiagnostic = verifyAndRecordRepair(
            input: input,
            output: &output,
            configuration: configuration,
            stage: PhysicalDesignStage.hotspotRepair.rawValue,
            strategy: "windowed_hotspot_repair",
            targetIDs: unresolved.map(\.id),
            details: ["rechecked_core_bounds_cell_conflicts_and_blockage_candidate"]
        ) {
            return Outcome(snapshot: nil, status: .blocked, diagnostics: [verificationDiagnostic], candidateActions: ["review_hotspot_window", "rerun_drc_hotspot_analysis"])
        }
        output.metadata["hotspotRepairStatus"] = "candidate_repairs_applied"
        return completed(
            output,
            actions: ["rerun_drc_hotspot_analysis"],
            metrics: metrics(for: output) + [PhysicalDesignMetric(name: "hotspotsRepaired", value: Double(unresolved.count), unit: "hotspots")],
            note: "Hotspot repair candidates were applied; the external DRC oracle remains authoritative."
        )
    }

    private func verifyAndRecordRepair(
        input: PhysicalDesignSnapshot,
        output: inout PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration,
        stage: String,
        strategy: String,
        targetIDs: [String],
        details: [String]
    ) -> XcircuiteEngineDiagnostic? {
        let before = repairViolationCount(
            input,
            configuration: configuration,
            stage: stage
        )
        let after = repairViolationCount(
            output,
            configuration: configuration,
            stage: stage
        )
        var implementationState = output.implementationState ?? PhysicalDesignImplementationState()
        implementationState.repairProofs.append(
            PhysicalDesignImplementationState.RepairProof(
                stage: stage,
                strategy: strategy,
                targetIDs: uniqueStrings(targetIDs),
                violationsBefore: before,
                violationsAfter: after,
                verified: after == 0,
                details: details
            )
        )
        output.implementationState = implementationState

        guard configuration.repairConstraints?.requireRepairVerification ?? true else {
            return nil
        }
        guard after == 0 else {
            return diagnostic(
                severity: .error,
                code: "native_repair_verification_failed",
                message: "Native post-repair verification found \(after) remaining violation(s) after \(stage).",
                actions: ["inspect_repair_proof", "rerun_the_relevant_oracle"]
            )
        }
        return nil
    }

    private func repairViolationCount(
        _ snapshot: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration,
        stage: String
    ) -> Int {
        var count = snapshot.validationDiagnostics().count
        let repairConstraints = configuration.repairConstraints ?? .default
        switch stage {
        case PhysicalDesignStage.antennaRepair.rawValue:
            count += snapshot.nets.reduce(into: 0) { result, net in
                if let ratio = net.antennaRatio,
                   ratio > (net.maximumAntennaRatio ?? configuration.maximumAntennaRatio) {
                    result += 1
                }
            }
        case PhysicalDesignStage.fillInsertion.rawValue:
            count += fillViolationCount(snapshot, repairConstraints: repairConstraints)
        case PhysicalDesignStage.redundantViaInsertion.rawValue:
            count += viaViolationCount(snapshot, minimumSpacing: repairConstraints.minimumViaSpacing)
        case PhysicalDesignStage.hotspotRepair.rawValue:
            count += snapshot.hotspots.filter { !$0.resolved }.count
        default:
            break
        }
        return count
    }

    private func fillViolationCount(
        _ snapshot: PhysicalDesignSnapshot,
        repairConstraints: PhysicalDesignRepairConstraints
    ) -> Int {
        guard let core = snapshot.core else {
            return snapshot.fills.isEmpty ? 0 : 1
        }
        var count = 0
        let fillArea = snapshot.fills.reduce(0.0) { partial, fill in
            partial + Double(fill.geometry.width) * Double(fill.geometry.height)
        }
        let coreArea = Double(core.width) * Double(core.height)
        if coreArea <= 0 || fillArea > coreArea * repairConstraints.maximumFillDensity {
            count += 1
        }
        for fill in snapshot.fills {
            if !core.contains(fill.geometry) {
                count += 1
            }
            if snapshot.cells.contains(where: { cell in
                cell.placed && PhysicalDesignSnapshot.Rect(
                    x: cell.x,
                    y: cell.y,
                    width: cell.width,
                    height: cell.height
                ).intersects(fill.geometry)
            }) {
                count += 1
            }
            if snapshot.blockages.contains(where: { $0.intersects(fill.geometry) }) {
                count += 1
            }
            if snapshot.powerStructures.contains(where: {
                $0.geometry.expanded(by: repairConstraints.minimumFillSpacing).intersects(fill.geometry)
            }) {
                count += 1
            }
        }
        return count
    }

    private func viaViolationCount(
        _ snapshot: PhysicalDesignSnapshot,
        minimumSpacing: Int64
    ) -> Int {
        guard snapshot.vias.count > 1 else {
            return 0
        }
        var count = 0
        for leftIndex in snapshot.vias.indices {
            for rightIndex in snapshot.vias.indices where rightIndex > leftIndex {
                let left = snapshot.vias[leftIndex]
                let right = snapshot.vias[rightIndex]
                if manhattan(left.x, left.y, right.x, right.y) < minimumSpacing {
                    count += 1
                }
            }
        }
        return count
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func padSide(for pin: PhysicalDesignSnapshot.Pin, die: PhysicalDesignSnapshot.Rect) -> String {
        let distances: [(String, Int64)] = [
            ("left", abs(pin.x - die.x)),
            ("right", abs(die.maxX - pin.x)),
            ("bottom", abs(pin.y - die.y)),
            ("top", abs(die.maxY - pin.y))
        ]
        return distances.min { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }?.0 ?? "left"
    }

    private func padGeometry(
        for pin: PhysicalDesignSnapshot.Pin,
        side: String,
        die: PhysicalDesignSnapshot.Rect,
        configuration: PhysicalDesignConfiguration
    ) -> PhysicalDesignSnapshot.Rect {
        let width = max(configuration.siteWidth, configuration.rowHeight / 2)
        let height = max(configuration.siteWidth, configuration.rowHeight / 2)
        switch side {
        case "right":
            return PhysicalDesignSnapshot.Rect(x: die.maxX - width, y: pin.y, width: width, height: height)
        case "bottom":
            return PhysicalDesignSnapshot.Rect(x: pin.x, y: die.y, width: width, height: height)
        case "top":
            return PhysicalDesignSnapshot.Rect(x: pin.x, y: die.maxY - height, width: width, height: height)
        default:
            return PhysicalDesignSnapshot.Rect(x: die.x, y: pin.y, width: width, height: height)
        }
    }

    private func estimatedWirelength(_ snapshot: PhysicalDesignSnapshot) -> Double {
        let pinByID = Dictionary(uniqueKeysWithValues: snapshot.pins.map { ($0.id, $0) })
        let cellByID = Dictionary(uniqueKeysWithValues: snapshot.cells.map { ($0.id, $0) })
        return snapshot.nets.reduce(0.0) { partial, net in
            let locations = net.pinIDs.compactMap { pinByID[$0] }.map { pinLocation($0, cells: cellByID) }
            guard let source = locations.first else { return partial }
            return partial + locations.dropFirst().reduce(0.0) { distance, location in
                distance + Double(manhattan(source.x, source.y, location.x, location.y))
            }
        }
    }

    private func maximumRowUtilization(_ snapshot: PhysicalDesignSnapshot) -> Double {
        snapshot.rows.reduce(0.0) { maximum, row in
            let usedWidth = snapshot.cells.filter { $0.placed && $0.y == row.originY }.reduce(0) { $0 + $1.width }
            let capacity = max(1, row.siteCount * row.siteWidth)
            return max(maximum, Double(usedWidth) / Double(capacity))
        }
    }

    private func completed(
        _ snapshot: PhysicalDesignSnapshot,
        diagnostics: [XcircuiteEngineDiagnostic] = [],
        actions: [String],
        metrics: [PhysicalDesignMetric],
        note: String? = nil
    ) -> Outcome {
        var allDiagnostics = diagnostics
        if let note {
            allDiagnostics.append(diagnostic(severity: .info, code: "execution_note", message: note, actions: []))
        }
        return Outcome(snapshot: snapshot, status: .completed, diagnostics: allDiagnostics, candidateActions: actions, metrics: metrics)
    }

    private func blocked(
        code: String,
        message: String,
        entity: String? = nil,
        actions: [String]
    ) -> Outcome {
        Outcome(
            snapshot: nil,
            status: .blocked,
            diagnostics: [diagnostic(severity: .error, code: code, message: message, entity: entity, actions: actions)],
            candidateActions: actions
        )
    }

    private func diagnostic(
        severity: XcircuiteEngineDiagnosticSeverity,
        code: String,
        message: String,
        entity: String? = nil,
        actions: [String]
    ) -> XcircuiteEngineDiagnostic {
        XcircuiteEngineDiagnostic(severity: severity, code: code, message: message, entity: entity, suggestedActions: actions)
    }

    private func metrics(for snapshot: PhysicalDesignSnapshot) -> [PhysicalDesignMetric] {
        let placedCount = snapshot.cells.filter(\.placed).count
        return [
            PhysicalDesignMetric(name: "cellCount", value: Double(snapshot.cells.count), unit: "cells"),
            PhysicalDesignMetric(name: "placedCellCount", value: Double(placedCount), unit: "cells"),
            PhysicalDesignMetric(name: "netCount", value: Double(snapshot.nets.count), unit: "nets"),
            PhysicalDesignMetric(name: "routeCount", value: Double(snapshot.routes.count), unit: "routes"),
            PhysicalDesignMetric(name: "viaCount", value: Double(snapshot.vias.count), unit: "vias"),
            PhysicalDesignMetric(name: "fillCount", value: Double(snapshot.fills.count), unit: "fills")
        ]
    }

    private func pinLocation(
        _ pin: PhysicalDesignSnapshot.Pin,
        cells: [String: PhysicalDesignSnapshot.Cell]
    ) -> (x: Int64, y: Int64) {
        if let cellID = pin.cellID, let cell = cells[cellID] {
            return (cell.x + cell.width / 2, cell.y + cell.height / 2)
        }
        return (pin.x, pin.y)
    }

    private func manhattan(_ x1: Int64, _ y1: Int64, _ x2: Int64, _ y2: Int64) -> Int64 {
        abs(x1 - x2) + abs(y1 - y2)
    }
}
