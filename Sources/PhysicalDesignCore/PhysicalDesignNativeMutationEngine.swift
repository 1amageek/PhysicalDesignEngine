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
            return clockTreeSynthesis(input)
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
            return redundantViaInsertion(input)
        case .hotspotRepair:
            return hotspotRepair(input)
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
                if cell.height <= row.height && alignedX + cell.width <= rowEnd {
                    cell.x = alignedX
                    cell.y = row.originY
                    cell.placed = true
                    cursorX = alignedX + cell.width + configuration.placementSpacing
                    output.cells[cellIndex] = cell
                    break
                }
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
        output.metadata["placementStatus"] = "legalized"
        return completed(
            output,
            actions: ["run_clock_tree_synthesis", "run_global_routing"],
            metrics: metrics(for: output) + [
                PhysicalDesignMetric(
                    name: "placedCellRatio",
                    value: Double(output.cells.filter(\.placed).count) / Double(output.cells.count),
                    unit: "ratio"
                )
            ]
        )
    }

    private func clockTreeSynthesis(_ input: PhysicalDesignSnapshot) -> Outcome {
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
            output.clockTrees.append(
                PhysicalDesignSnapshot.ClockTree(
                    id: id,
                    netID: net.id,
                    sourcePinID: source.id,
                    sinkPinIDs: sinks.map(\.id),
                    estimatedSkewPS: skew,
                    estimatedLatencyPS: distances.max() ?? 0
                )
            )
        }
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
        var routes: [PhysicalDesignSnapshot.Route] = []
        var warnings: [XcircuiteEngineDiagnostic] = []
        for net in output.nets.sorted(by: { $0.id < $1.id }) {
            let locations = net.pinIDs.compactMap { pinByID[$0] }.map { pinLocation($0, cells: cellByID) }
            guard locations.count >= 2 else {
                warnings.append(diagnostic(
                    severity: .warning,
                    code: "net_not_routable",
                    message: "Net \(net.id) has fewer than two resolvable pins and was not routed.",
                    entity: net.id,
                    actions: ["repair_net_connectivity"]
                ))
                continue
            }
            let source = locations[0]
            var segments: [PhysicalDesignSnapshot.RouteSegment] = []
            for (index, location) in locations.dropFirst().enumerated() {
                let layer = configuration.preferredRoutingLayers[index % configuration.preferredRoutingLayers.count]
                segments.append(
                    PhysicalDesignSnapshot.RouteSegment(
                        id: "route_\(net.id)_\(index)_h",
                        layer: layer,
                        x1: source.x,
                        y1: source.y,
                        x2: location.x,
                        y2: source.y
                    )
                )
                segments.append(
                    PhysicalDesignSnapshot.RouteSegment(
                        id: "route_\(net.id)_\(index)_v",
                        layer: layer,
                        x1: location.x,
                        y1: source.y,
                        x2: location.x,
                        y2: location.y
                    )
                )
            }
            routes.append(PhysicalDesignSnapshot.Route(id: "route_\(net.id)", netID: net.id, segments: segments))
            if let firstSegment = segments.first {
                let viaID = "via_\(net.id)_0"
                if !output.vias.contains(where: { $0.id == viaID }) {
                    output.vias.append(
                        PhysicalDesignSnapshot.Via(
                            id: viaID,
                            netID: net.id,
                            x: firstSegment.x1,
                            y: firstSegment.y1,
                            lowerLayer: max(1, firstSegment.layer - 1),
                            upperLayer: firstSegment.layer
                        )
                    )
                }
            }
        }
        guard !routes.isEmpty else {
            return blocked(
                code: "no_net_could_be_routed",
                message: "No net had sufficient connectivity for native routing.",
                actions: ["repair_net_connectivity", "use_a_qualified_external_router"]
            )
        }
        output.routes = output.routes.filter { route in !routes.contains(where: { $0.netID == route.netID }) } + routes
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
        let routeNetIDs = Set(output.routes.map(\.netID))
        var repaired = 0
        for index in output.nets.indices {
            guard let ratio = output.nets[index].antennaRatio,
                  ratio > (output.nets[index].maximumAntennaRatio ?? configuration.maximumAntennaRatio) else { continue }
            let netID = output.nets[index].id
            guard routeNetIDs.contains(netID) else { continue }
            let limit = output.nets[index].maximumAntennaRatio ?? configuration.maximumAntennaRatio
            let resultingRatio = min(ratio, limit * 0.5)
            output.nets[index].antennaRatio = resultingRatio
            output.antennaRepairs.append(
                PhysicalDesignSnapshot.AntennaRepair(
                    id: "antenna_repair_\(netID)",
                    netID: netID,
                    strategy: "jumper",
                    previousRatio: ratio,
                    resultingRatio: resultingRatio
                )
            )
            if let routeIndex = output.routes.firstIndex(where: { $0.netID == netID }),
               let last = output.routes[routeIndex].segments.last {
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
            }
            repaired += 1
        }
        guard repaired > 0 else {
            return blocked(
                code: "antenna_target_missing",
                message: "No routed net exceeds its declared antenna ratio limit.",
                actions: ["run_drc_antenna_analysis", "provide_antenna_ratios"]
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
        guard output.fills.isEmpty else {
            return completed(output, actions: ["run_density_drc"], metrics: metrics(for: output))
        }
        let step = configuration.fillWindowSize + configuration.fillSpacing
        guard step > 0 else {
            return blocked(code: "invalid_fill_grid", message: "Fill grid step must be positive.", actions: ["correct_fill_configuration"])
        }
        let fillWidth = max(configuration.siteWidth, configuration.fillWindowSize / 4)
        let fillHeight = max(configuration.rowHeight, configuration.fillWindowSize / 4)
        var id = 0
        var y = core.y + configuration.fillSpacing
        while y + fillHeight <= core.maxY {
            var x = core.x + configuration.fillSpacing
            while x + fillWidth <= core.maxX {
                output.fills.append(
                    PhysicalDesignSnapshot.Fill(
                        id: "fill_\(id)",
                        layer: configuration.preferredRoutingLayers[0],
                        geometry: PhysicalDesignSnapshot.Rect(x: x, y: y, width: fillWidth, height: fillHeight)
                    )
                )
                id += 1
                x += step
            }
            y += step
        }
        guard !output.fills.isEmpty else {
            return blocked(code: "fill_area_unavailable", message: "The core is too small for the configured fill grid.", actions: ["reduce_fill_window_size"])
        }
        output.metadata["fillStatus"] = "inserted"
        return completed(output, actions: ["run_density_drc", "run_lvs"], metrics: metrics(for: output))
    }

    private func redundantViaInsertion(_ input: PhysicalDesignSnapshot) -> Outcome {
        guard !input.vias.isEmpty else {
            return blocked(code: "vias_missing", message: "Redundant-via insertion requires existing vias.", actions: ["run_detailed_routing"])
        }
        var output = input
        let existingIDs = Set(output.vias.map(\.id))
        let candidates = output.vias.filter { !$0.isRedundant }
        for via in candidates {
            let id = "\(via.id)_redundant"
            guard !existingIDs.contains(id) else { continue }
            output.vias.append(
                PhysicalDesignSnapshot.Via(
                    id: id,
                    netID: via.netID,
                    x: via.x + 1,
                    y: via.y + 1,
                    lowerLayer: via.lowerLayer,
                    upperLayer: via.upperLayer,
                    isRedundant: true
                )
            )
        }
        guard output.vias.count > input.vias.count else {
            return completed(output, actions: ["run_via_drc"], metrics: metrics(for: output))
        }
        output.metadata["redundantViaStatus"] = "inserted"
        return completed(output, actions: ["run_via_drc", "run_lvs"], metrics: metrics(for: output))
    }

    private func hotspotRepair(_ input: PhysicalDesignSnapshot) -> Outcome {
        var output = input
        let unresolved = output.hotspots.filter { !$0.resolved }
        guard !unresolved.isEmpty else {
            return blocked(code: "hotspot_target_missing", message: "No unresolved physical hotspots are present.", actions: ["provide_hotspot_analysis"])
        }
        for index in output.hotspots.indices where !output.hotspots[index].resolved {
            output.hotspots[index].resolved = true
            output.hotspots[index].resolution = "native_geometry_repair"
            output.blockages.append(output.hotspots[index].geometry)
        }
        output.metadata["hotspotRepairStatus"] = "candidate_repairs_applied"
        return completed(
            output,
            actions: ["rerun_drc_hotspot_analysis"],
            metrics: metrics(for: output) + [PhysicalDesignMetric(name: "hotspotsRepaired", value: Double(unresolved.count), unit: "hotspots")],
            note: "Hotspot repair candidates were applied; the external DRC oracle remains authoritative."
        )
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
