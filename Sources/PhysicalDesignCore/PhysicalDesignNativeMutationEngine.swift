import Foundation
import CircuiteFoundation

public struct PhysicalDesignNativeMutationEngine: Sendable {
    public struct Outcome: Sendable, Hashable {
        public var snapshot: PhysicalDesignSnapshot?
        public var status: PhysicalDesignExecutionStatus
        public var diagnostics: [DesignDiagnostic]
        public var candidateActions: [String]
        public var metrics: [PhysicalDesignMetric]

        public init(
            snapshot: PhysicalDesignSnapshot?,
            status: PhysicalDesignExecutionStatus,
            diagnostics: [DesignDiagnostic] = [],
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

        let outcome: Outcome
        switch request.stage {
        case .floorplan:
            outcome = floorplan(input, configuration: request.configuration)
        case .powerPlanning:
            outcome = powerPlanning(input, configuration: request.configuration)
        case .placement:
            outcome = placement(input, configuration: request.configuration)
        case .clockTreeSynthesis:
            outcome = clockTreeSynthesis(input, configuration: request.configuration)
        case .globalRouting:
            outcome = routing(input, configuration: request.configuration, mode: "global")
        case .detailedRouting:
            outcome = routing(input, configuration: request.configuration, mode: "detailed")
        case .timingECO, .drcRepair:
            outcome = eco(input, configuration: request.configuration, stage: request.stage)
        case .antennaRepair:
            outcome = antennaRepair(input, configuration: request.configuration)
        case .fillInsertion:
            outcome = fillInsertion(input, configuration: request.configuration)
        case .redundantViaInsertion:
            outcome = redundantViaInsertion(input, configuration: request.configuration)
        case .hotspotRepair:
            outcome = hotspotRepair(input, configuration: request.configuration)
        }
        return validateCompletedOutcome(outcome)
    }

    private func validateCompletedOutcome(_ outcome: Outcome) -> Outcome {
        guard outcome.status == .completed, let snapshot = outcome.snapshot else { return outcome }
        let diagnostics = snapshot.validationDiagnostics()
        guard diagnostics.isEmpty else {
            return blocked(
                code: "invalid_output_snapshot",
                message: diagnostics.joined(separator: "; "),
                actions: ["inspect_native_mutation_output", "repair_the_canonical_snapshot"]
            )
        }
        return outcome
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
        guard configuration.siteWidth < min(core.width, core.height) else {
            return blocked(
                code: "power_geometry_invalid",
                message: "Power ring and rail width must be smaller than both core dimensions.",
                actions: ["reduce_power_structure_width", "increase_core_area"]
            )
        }
        let startingCount = output.powerStructures.count
        var existingIDs = Set(output.powerStructures.map(\.id))
        let existingViaIDs = Set(output.vias.map(\.id))
        var powerViasAdded = 0
        for (netIndex, netID) in configuration.powerNetNames.enumerated() {
            let sourcePinID = "power_\(netID)_source"
            let sinkPinID = "power_\(netID)_sink"
            if !output.pins.contains(where: { $0.id == sourcePinID }) {
                output.pins.append(PhysicalDesignSnapshot.Pin(
                    id: sourcePinID,
                    name: "\(netID)_SOURCE",
                    x: core.x,
                    y: core.y + core.height / 2,
                    netID: netID,
                    direction: "inout"
                ))
            }
            if !output.pins.contains(where: { $0.id == sinkPinID }) {
                output.pins.append(PhysicalDesignSnapshot.Pin(
                    id: sinkPinID,
                    name: "\(netID)_SINK",
                    x: core.maxX,
                    y: core.y + core.height / 2,
                    netID: netID,
                    direction: "inout"
                ))
            }
            if let netIndexInSnapshot = output.nets.firstIndex(where: { $0.id == netID }) {
                for pinID in [sourcePinID, sinkPinID] where !output.nets[netIndexInSnapshot].pinIDs.contains(pinID) {
                    output.nets[netIndexInSnapshot].pinIDs.append(pinID)
                }
            } else {
                output.nets.append(PhysicalDesignSnapshot.Net(
                    id: netID,
                    pinIDs: [sourcePinID, sinkPinID]
                ))
            }
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
                existingIDs.insert(id)
            }
            let strapCount = max(1, core.width / max(configuration.fillWindowSize, configuration.siteWidth * 10))
            let strapDenominator = strapCount + 1 + Int64(configuration.powerNetNames.count)
            for index in 0..<strapCount {
                let strapNumerator = (index + 1 + Int64(netIndex)) * core.width
                let x = core.x + strapNumerator / strapDenominator
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
                existingIDs.insert(id)
            }
            let railCount = max(1, core.height / max(configuration.fillWindowSize, configuration.siteWidth * 10))
            let railDenominator = railCount + 1 + Int64(configuration.powerNetNames.count)
            for index in 0..<railCount {
                let railNumerator = (index + 1 + Int64(netIndex)) * core.height
                let y = core.y + railNumerator / railDenominator
                let id = "power_\(netID)_rail_\(index)"
                guard !existingIDs.contains(id) else { continue }
                output.powerStructures.append(
                    PhysicalDesignSnapshot.PowerStructure(
                        id: id,
                        netID: netID,
                        kind: "rail",
                        layer: 1 + netIndex,
                        geometry: PhysicalDesignSnapshot.Rect(
                            x: core.x,
                            y: y,
                            width: core.width,
                            height: configuration.siteWidth
                        )
                    )
                )
                existingIDs.insert(id)
                for strapIndex in 0..<strapCount {
                    let strapNumerator = (strapIndex + 1 + Int64(netIndex)) * core.width
                    let x = core.x + strapNumerator / strapDenominator
                    let viaID = "power_\(netID)_via_\(strapIndex)_\(index)"
                    let via = PhysicalDesignSnapshot.Via(
                        id: viaID,
                        netID: netID,
                        x: x,
                        y: y,
                        lowerLayer: 1 + netIndex,
                        upperLayer: 2 + netIndex
                    )
                    guard !existingViaIDs.contains(viaID), !output.vias.contains(where: {
                        manhattan($0.x, $0.y, via.x, via.y) < (configuration.repairConstraints ?? .default).minimumViaSpacing
                    }) else { continue }
                    output.vias.append(via)
                    powerViasAdded += 1
                }
            }
        }
        output.metadata["powerPlanningStatus"] = "generated"
        let added = output.powerStructures.count - startingCount
        return completed(
            output,
            actions: ["run_placement", "run_global_routing", "verify_power_connectivity"],
            metrics: metrics(for: output) + [
                PhysicalDesignMetric(name: "powerStructuresAdded", value: Double(added), unit: "structures"),
                PhysicalDesignMetric(name: "powerViasAdded", value: Double(powerViasAdded), unit: "vias"),
                PhysicalDesignMetric(name: "powerConnectivityNets", value: Double(configuration.powerNetNames.count), unit: "nets")
            ]
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
                    let previousCell = output.cells[cellIndex]
                    for pinIndex in output.pins.indices where output.pins[pinIndex].cellID == cell.id {
                        let (offsetX, offsetXOverflow) = output.pins[pinIndex].x.subtractingReportingOverflow(previousCell.x)
                        let (offsetY, offsetYOverflow) = output.pins[pinIndex].y.subtractingReportingOverflow(previousCell.y)
                        guard !offsetXOverflow, !offsetYOverflow else {
                            return blocked(
                                code: "placement_pin_coordinate_overflow",
                                message: "Placement could not translate pin geometry for cell \(cell.id) without overflowing the coordinate range.",
                                entity: cell.id,
                                actions: ["repair_pin_geometry", "reduce_placement_coordinate_range"]
                            )
                        }
                        let (newPinX, newPinXOverflow) = cell.x.addingReportingOverflow(offsetX)
                        let (newPinY, newPinYOverflow) = cell.y.addingReportingOverflow(offsetY)
                        guard !newPinXOverflow, !newPinYOverflow else {
                            return blocked(
                                code: "placement_pin_coordinate_overflow",
                                message: "Placement could not translate pin geometry for cell \(cell.id) without overflowing the coordinate range.",
                                entity: cell.id,
                                actions: ["repair_pin_geometry", "reduce_placement_coordinate_range"]
                            )
                        }
                        output.pins[pinIndex].x = newPinX
                        output.pins[pinIndex].y = newPinY
                    }
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
        let blockedCellCount = output.cells.filter { cell in
            let geometry = PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)
            return output.blockages.contains(where: { $0.intersects(geometry) })
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
            blockedCellCount: blockedCellCount,
            utilization: utilization,
            timingObjective: timingObjective,
            congestionObjective: congestionObjective
        )
        output.implementationState = implementationState
        if overlapCount > 0 || outsideCoreCount > 0 || blockedCellCount > 0 {
            return blocked(
                code: "placement_legality_failed",
                message: "Placement produced overlap, core-boundary or blockage conflicts.",
                actions: ["repair_placement_conflicts", "increase_core_area", "adjust_placement_blockages"]
            )
        }
        var placementDiagnostics: [DesignDiagnostic] = []
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
        guard let core = input.core else {
            return blocked(
                code: "core_geometry_missing",
                message: "Clock-tree synthesis requires a core rectangle to bound generated clock routes.",
                actions: ["run_floorplan"]
            )
        }
        var implementationState = output.implementationState ?? PhysicalDesignImplementationState()
        var skewDiagnostics: [DesignDiagnostic] = []
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
            let id = "clock_tree_\(net.id)"
            guard !existingIDs.contains(id) else { continue }
            var parentPinIDs: [String] = [source.id]
            var bufferCellIDs: [String] = []
            var sinkPathLengths: [Int64] = []
            var bufferIndex = 0
            for (sinkIndex, sink) in sinks.enumerated() {
                let distance = distances[sinkIndex]
                guard distance > implementationConstraints.clockTargetSkewPS else {
                    parentPinIDs.append(sink.id)
                    sinkPathLengths.append(distance)
                    continue
                }
                let targetY = midpoint(source.y, sink.y)
                guard let row = output.rows.sorted(by: { $0.id < $1.id }).min(by: { lhs, rhs in
                    absoluteDifference(lhs.originY, targetY) < absoluteDifference(rhs.originY, targetY)
                }) else {
                    return blocked(
                        code: "cts_rows_missing",
                        message: "Clock buffering requires placement rows to materialize buffer cells.",
                        entity: net.id,
                        actions: ["run_floorplan_before_clock_tree_synthesis"]
                    )
                }
                let width = max(configuration.siteWidth * 2, implementationConstraints.routeWidth)
                let x = max(row.originX, min(midpoint(source.x, sink.x), row.originX + row.siteCount * row.siteWidth - width))
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
                sinkPathLengths.append(
                    manhattan(source.x, source.y, x, y + row.height / 2)
                        + manhattan(x + width, y + row.height / 2, sink.x, sink.y)
                )
                implementationState.clockRouteConstraints.append(PhysicalDesignImplementationState.ClockRouteConstraint(
                    id: "clock_route_\(branchNetID)",
                    netID: branchNetID,
                    layer: implementationConstraints.clockRouteLayer,
                    width: implementationConstraints.routeWidth,
                    spacing: implementationConstraints.routeSpacing,
                    maximumLength: max(1, implementationConstraints.clockTargetSkewPS * 4),
                    maximumTransitionPS: implementationConstraints.clockMaximumTransitionPS
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
                    estimatedSkewPS: (sinkPathLengths.max() ?? 0) - (sinkPathLengths.min() ?? 0),
                    estimatedLatencyPS: sinkPathLengths.max() ?? 0
                )
            )
            if let tree = output.clockTrees.last,
               tree.estimatedSkewPS > implementationConstraints.clockTargetSkewPS {
                skewDiagnostics.append(diagnostic(
                    severity: .warning,
                    code: "cts_target_skew_unmet",
                    message: "Clock tree \(tree.id) has estimated skew \(tree.estimatedSkewPS) ps above the target \(implementationConstraints.clockTargetSkewPS) ps.",
                    entity: tree.id,
                    actions: ["run_timing_analysis", "use_a_qualified_external_cts"]
                ))
            }
            implementationState.clockRouteConstraints.append(PhysicalDesignImplementationState.ClockRouteConstraint(
                id: "clock_route_\(net.id)",
                netID: net.id,
                layer: implementationConstraints.clockRouteLayer,
                width: implementationConstraints.routeWidth,
                spacing: implementationConstraints.routeSpacing,
                maximumLength: max(1, implementationConstraints.clockTargetSkewPS * 4),
                maximumTransitionPS: implementationConstraints.clockMaximumTransitionPS
            ))
        }
        let clockTreeIDs = Set(output.clockTrees.map(\.netID))
        var clockRouteGeometries = output.routes
            .filter { !clockTreeIDs.contains($0.netID) }
            .flatMap { route in
                route.segments.map {
                    (netID: route.netID, layer: $0.layer, geometry: segmentGeometry($0, width: implementationConstraints.routeWidth))
                }
            }
        var materializedClockRoutes: [PhysicalDesignSnapshot.Route] = []
        var materializedClockVias: [PhysicalDesignSnapshot.Via] = []
        for tree in output.clockTrees {
            guard let materialization = materializeClockTree(
                tree,
                snapshot: output,
                core: core,
                configuration: configuration,
                existingGeometries: &clockRouteGeometries
            ) else {
                return blocked(
                    code: "cts_route_materialization_failed",
                    message: "Clock tree \(tree.id) could not be materialized within the core, blockages and route spacing constraints.",
                    entity: tree.id,
                    actions: ["repair_clock_geometry", "move_clock_blockages", "use_a_qualified_external_cts"]
                )
            }
            materializedClockRoutes.append(contentsOf: materialization.routes)
            materializedClockVias.append(contentsOf: materialization.vias)
        }
        output.routes = output.routes.filter { !clockTreeIDs.contains($0.netID) } + materializedClockRoutes
        let existingViaIDs = Set(output.vias.map(\.id))
        output.vias.append(contentsOf: materializedClockVias.filter { !existingViaIDs.contains($0.id) })
        output.implementationState = implementationState
        output.metadata["clockTreeStatus"] = "constructed"
        return completed(
            output,
            diagnostics: skewDiagnostics,
            actions: ["run_detailed_routing", "run_timing_analysis"],
            metrics: metrics(for: output) + [
                PhysicalDesignMetric(name: "clockTreeCount", value: Double(output.clockTrees.count), unit: "trees")
            ]
        )
    }

    private struct ClockRouteMaterialization: Sendable {
        var routes: [PhysicalDesignSnapshot.Route]
        var vias: [PhysicalDesignSnapshot.Via]
    }

    private func materializeClockTree(
        _ tree: PhysicalDesignSnapshot.ClockTree,
        snapshot: PhysicalDesignSnapshot,
        core: PhysicalDesignSnapshot.Rect,
        configuration: PhysicalDesignConfiguration,
        existingGeometries: inout [(netID: String, layer: Int, geometry: PhysicalDesignSnapshot.Rect)]
    ) -> ClockRouteMaterialization? {
        let implementationConstraints = configuration.implementationConstraints ?? .default
        let horizontalLayers = configuration.preferredRoutingLayers.filter { !$0.isMultiple(of: 2) }.sorted()
        let verticalLayers = configuration.preferredRoutingLayers.filter { $0.isMultiple(of: 2) }.sorted()
        guard let horizontalLayer = horizontalLayers.first(where: { $0 == implementationConstraints.clockRouteLayer }) ?? horizontalLayers.first,
              let verticalLayer = verticalLayers.last ?? verticalLayers.first else {
            return nil
        }
        let pinByID = Dictionary(uniqueKeysWithValues: snapshot.pins.map { ($0.id, $0) })
        guard pinByID[tree.sourcePinID] != nil else { return nil }
        var endpoints: [(netID: String, sourcePinID: String, sinkPinID: String)] = []
        if let net = snapshot.nets.first(where: { $0.id == tree.netID }) {
            endpoints.append(contentsOf: net.pinIDs.filter { $0 != tree.sourcePinID }.map { (netID: tree.netID, sourcePinID: tree.sourcePinID, sinkPinID: $0) })
        }
        for bufferCellID in tree.bufferCellIDs {
            let outputPinID = "pin_\(bufferCellID)_Y"
            guard let branchNet = snapshot.nets.first(where: { $0.pinIDs.contains(outputPinID) }) else { return nil }
            endpoints.append(contentsOf: branchNet.pinIDs.filter { $0 != outputPinID }.map { (netID: branchNet.id, sourcePinID: outputPinID, sinkPinID: $0) })
        }
        guard !endpoints.isEmpty else { return nil }

        var routes: [PhysicalDesignSnapshot.Route] = []
        var vias: [PhysicalDesignSnapshot.Via] = []
        let cellByID = Dictionary(uniqueKeysWithValues: snapshot.cells.map { ($0.id, $0) })
        for (ordinal, endpoint) in endpoints.enumerated() {
            guard let endpointSourcePin = pinByID[endpoint.sourcePinID] else { return nil }
            guard let sinkPin = pinByID[endpoint.sinkPinID] else { return nil }
            let endpointSource = pinLocation(endpointSourcePin, cells: cellByID)
            let target = pinLocation(sinkPin, cells: cellByID)
            guard endpointSource != target else { return nil }
            guard let path = clockPath(
                from: endpointSource,
                to: target,
                netID: endpoint.netID,
                routeID: "clock_route_\(endpoint.netID)_\(ordinal)",
                horizontalLayer: horizontalLayer,
                verticalLayer: verticalLayer,
                core: core,
                blockages: snapshot.blockages,
                configuration: configuration,
                clockFamilyID: tree.netID,
                existingGeometries: &existingGeometries
            ) else {
                return nil
            }
            routes.append(path.route)
            if let via = path.via {
                vias.append(via)
            }
        }
        return ClockRouteMaterialization(routes: routes, vias: vias)
    }

    private struct ClockPath {
        var route: PhysicalDesignSnapshot.Route
        var via: PhysicalDesignSnapshot.Via?
    }

    private func clockPath(
        from source: (x: Int64, y: Int64),
        to target: (x: Int64, y: Int64),
        netID: String,
        routeID: String,
        horizontalLayer: Int,
        verticalLayer: Int,
        core: PhysicalDesignSnapshot.Rect,
        blockages: [PhysicalDesignSnapshot.Rect],
        configuration: PhysicalDesignConfiguration,
        clockFamilyID: String,
        existingGeometries: inout [(netID: String, layer: Int, geometry: PhysicalDesignSnapshot.Rect)]
    ) -> ClockPath? {
        let implementationConstraints = configuration.implementationConstraints ?? .default
        var segments: [PhysicalDesignSnapshot.RouteSegment] = []
        var geometries: [(layer: Int, geometry: PhysicalDesignSnapshot.Rect)] = []
        if source.x != target.x {
            let segment = PhysicalDesignSnapshot.RouteSegment(
                id: "\(routeID)_h",
                layer: horizontalLayer,
                x1: source.x,
                y1: source.y,
                x2: target.x,
                y2: source.y
            )
            geometries.append((horizontalLayer, segmentGeometry(segment, width: implementationConstraints.routeWidth)))
            segments.append(segment)
        }
        if source.y != target.y {
            let segment = PhysicalDesignSnapshot.RouteSegment(
                id: "\(routeID)_v",
                layer: verticalLayer,
                x1: target.x,
                y1: source.y,
                x2: target.x,
                y2: target.y
            )
            geometries.append((verticalLayer, segmentGeometry(segment, width: implementationConstraints.routeWidth)))
            segments.append(segment)
        }
        guard !segments.isEmpty else { return nil }
        guard geometries.allSatisfy({ layer, geometry in
            core.contains(geometry)
                && !blockages.contains(where: { $0.intersects(geometry) })
                && !existingGeometries.contains {
                    !isClockFamilyNet($0.netID, familyID: clockFamilyID)
                        && $0.layer == layer
                        && $0.geometry.expanded(by: implementationConstraints.routeSpacing).intersects(geometry)
                }
        }) else { return nil }
        existingGeometries.append(contentsOf: geometries.map { (netID: netID, layer: $0.layer, geometry: $0.geometry) })
        let via: PhysicalDesignSnapshot.Via?
        if source.x != target.x, source.y != target.y {
            via = PhysicalDesignSnapshot.Via(
                id: "\(routeID)_via",
                netID: netID,
                x: target.x,
                y: source.y,
                lowerLayer: min(horizontalLayer, verticalLayer),
                upperLayer: max(horizontalLayer, verticalLayer)
            )
        } else {
            via = nil
        }
        return ClockPath(route: PhysicalDesignSnapshot.Route(id: routeID, netID: netID, segments: segments), via: via)
    }

    private func isClockFamilyNet(_ netID: String, familyID: String) -> Bool {
        netID == familyID || netID.hasPrefix("\(familyID)_branch_")
    }

    private func routing(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration,
        mode: String,
        onlyNetID: String? = nil
    ) -> Outcome {
        guard !input.cells.isEmpty, input.cells.allSatisfy(\.placed) else {
            return blocked(
                code: "placed_cells_missing",
                message: "Routing requires all cells to be legally placed.",
                actions: ["run_placement"]
            )
        }
        guard let core = input.core else {
            return blocked(
                code: "core_geometry_missing",
                message: "Routing requires a core rectangle to bound generated route geometry.",
                actions: ["run_floorplan"]
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
        let tracks = (output.implementationState?.tracks ?? []).filter {
            $0.layer > 0 && $0.layer <= configuration.maximumRoutingLayer
        }
        let powerNetIDs = Set(configuration.powerNetNames)
        let powerNetsWithoutStructures = output.nets
            .filter { powerNetIDs.contains($0.id) }
            .filter { net in
                !output.powerStructures.contains(where: { $0.netID == net.id })
            }
        guard powerNetsWithoutStructures.isEmpty else {
            return blocked(
                code: "power_connectivity_missing",
                message: "Power net(s) must be materialized by power structures before native signal routing can proceed: \(powerNetsWithoutStructures.map(\.id).sorted().joined(separator: ", ")).",
                actions: ["run_power_planning", "verify_power_connectivity"]
            )
        }
        let routableNets = output.nets
            .sorted(by: { $0.id < $1.id })
            .filter { !powerNetIDs.contains($0.id) }
            .filter { onlyNetID == nil || $0.id == onlyNetID }
        let reroutedNetIDs = Set(routableNets.map(\.id))
        var routes: [PhysicalDesignSnapshot.Route] = []
        var warnings: [DesignDiagnostic] = []
        var routeFailures: [DesignDiagnostic] = []
        var skippedNetIDs: [String] = []
        var blockageConflictCount = 0
        var layerDirectionViolations = 0
        var spacingConflicts = 0
        var antennaRiskNetIDs: [String] = []
        var routeGeometries: [(netID: String, layer: Int, geometry: PhysicalDesignSnapshot.Rect)] = []
        routeGeometries = output.routes
            .filter { !reroutedNetIDs.contains($0.netID) }
            .flatMap { route in
                route.segments.map {
                    (
                        netID: route.netID,
                        layer: $0.layer,
                        geometry: segmentGeometry($0, width: implementationConstraints.routeWidth)
                    )
                }
            }
        var generatedVias: [PhysicalDesignSnapshot.Via] = []
        for (netOrdinal, net) in routableNets.enumerated() {
            if Task.isCancelled {
                return cancelled(actions: ["resume_from_the_last_immutable_revision"])
            }
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
                guard source != location else {
                    routeFailures.append(diagnostic(
                        severity: .error,
                        code: "net_pins_collocated",
                        message: "Net \(net.id) contains distinct pins at the same physical location and cannot be represented by a native route segment.",
                        entity: net.id,
                        actions: ["repair_pin_geometry", "use_a_qualified_external_router"]
                    ))
                    netFailed = true
                    break
                }
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
                var pathSegments: [PhysicalDesignSnapshot.RouteSegment] = []
                if source.x != location.x {
                    pathSegments.append(PhysicalDesignSnapshot.RouteSegment(
                        id: "route_\(net.id)_\(index)_h",
                        layer: horizontalLayer,
                        x1: source.x,
                        y1: source.y,
                        x2: location.x,
                        y2: source.y
                    ))
                }
                if source.y != location.y {
                    pathSegments.append(PhysicalDesignSnapshot.RouteSegment(
                        id: "route_\(net.id)_\(index)_v",
                        layer: verticalLayer,
                        x1: location.x,
                        y1: source.y,
                        x2: location.x,
                        y2: location.y
                    ))
                }
                guard !pathSegments.isEmpty else {
                    routeFailures.append(diagnostic(
                        severity: .error,
                        code: "net_pins_collocated",
                        message: "Net \(net.id) contains distinct pins at the same physical location and cannot be represented by a native route segment.",
                        entity: net.id,
                        actions: ["repair_pin_geometry", "use_a_qualified_external_router"]
                    ))
                    netFailed = true
                    break
                }
                let geometries = pathSegments.map { segmentGeometry($0, width: implementationConstraints.routeWidth) }
                if geometries.contains(where: { !core.contains($0) }) {
                    routeFailures.append(diagnostic(
                        severity: .error,
                        code: "routing_core_boundary_conflict",
                        message: "Net \(net.id) would leave the core boundary during native routing.",
                        entity: net.id,
                        actions: ["repair_pin_geometry", "increase_core_area", "use_a_qualified_external_router"]
                    ))
                    netFailed = true
                    break
                }
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
                segments.append(contentsOf: pathSegments)
                segmentGeometries.append(contentsOf: geometries)
                if pathSegments.count == 2 {
                    generatedVias.append(PhysicalDesignSnapshot.Via(
                        id: "via_\(net.id)_\(index)",
                        netID: net.id,
                        x: location.x,
                        y: source.y,
                        lowerLayer: min(pathSegments[0].layer, pathSegments[1].layer),
                        upperLayer: max(pathSegments[0].layer, pathSegments[1].layer)
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
        guard skippedNetIDs.isEmpty else {
            let skipped = skippedNetIDs.sorted().joined(separator: ", ")
            return Outcome(
                snapshot: nil,
                status: .blocked,
                diagnostics: warnings + [diagnostic(
                    severity: .error,
                    code: "routing_incomplete",
                    message: "Routing could not establish connectivity for net(s): \(skipped).",
                    entity: skipped,
                    actions: ["repair_net_connectivity", "use_a_qualified_external_router"]
                )],
                candidateActions: ["repair_net_connectivity", "use_a_qualified_external_router"]
            )
        }
        guard !routes.isEmpty else {
            if routableNets.isEmpty {
                var implementationState = output.implementationState ?? PhysicalDesignImplementationState()
                implementationState.routingEvidence = PhysicalDesignImplementationState.RoutingEvidence(
                    mode: mode,
                    routedNetCount: 0,
                    skippedNetIDs: [],
                    viaCount: 0
                )
                output.implementationState = implementationState
                output.metadata["routingStatus"] = mode
                return completed(
                    output,
                    actions: ["run_drc", "run_lvs"],
                    metrics: metrics(for: output),
                    note: "Native \(mode) routing found no signal nets; declared power nets are represented by verified power structures."
                )
            }
            return blocked(
                code: "no_net_could_be_routed",
                message: "No net had sufficient connectivity for native routing.",
                actions: ["repair_net_connectivity", "use_a_qualified_external_router"]
            )
        }
        let existingViaIDs = Set(output.vias.map(\.id))
        let remainingVias = output.vias.filter { !reroutedNetIDs.contains($0.netID) }
        let minimumViaSpacing = (configuration.repairConstraints ?? .default).minimumViaSpacing
        let allVias = remainingVias + generatedVias
        if allVias.indices.contains(where: { leftIndex in
            allVias.indices.contains(where: { rightIndex in
                rightIndex > leftIndex
                    && manhattan(allVias[leftIndex].x, allVias[leftIndex].y, allVias[rightIndex].x, allVias[rightIndex].y) < minimumViaSpacing
            })
        }) {
            return blocked(
                code: "routing_via_spacing_conflict",
                message: "Native routing generated vias that violate the configured minimum via spacing.",
                actions: ["increase_via_spacing", "choose_another_routing_layer", "use_a_qualified_external_router"]
            )
        }
        output.vias = output.vias.filter { !reroutedNetIDs.contains($0.netID) }
        output.vias.append(contentsOf: generatedVias.filter { !existingViaIDs.contains($0.id) })
        output.routes = output.routes.filter { !reroutedNetIDs.contains($0.netID) } + routes
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
        return nil
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
                y: saturatedSubtract(segment.y1, halfWidth),
                width: max(1, absoluteDifference(segment.x2, segment.x1)),
                height: max(1, width)
            )
        }
        let minimumY = min(segment.y1, segment.y2)
        return PhysicalDesignSnapshot.Rect(
            x: saturatedSubtract(segment.x1, halfWidth),
            y: minimumY,
            width: max(1, width),
            height: max(1, absoluteDifference(segment.y2, segment.y1))
        )
    }

    private func eco(
        _ input: PhysicalDesignSnapshot,
        configuration: PhysicalDesignConfiguration,
        stage: PhysicalDesignStage
    ) -> Outcome {
        var output = input
        var netsToRoute: [String] = []
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
            guard !output.cells[index].locked else {
                return blocked(
                    code: "eco_locked_cell",
                    message: "ECO resize cannot mutate locked cell \(target).",
                    entity: target,
                    actions: ["unlock_the_cell_or_choose_another_target"]
                )
            }
            guard output.cells[index].width <= Int64.max - configuration.siteWidth else {
                return blocked(
                    code: "eco_resize_overflow",
                    message: "ECO resize would overflow the target cell geometry.",
                    entity: target,
                    actions: ["reduce_eco_resize_delta"]
                )
            }
            output.cells[index].width += configuration.siteWidth
            output.cells[index].master += "_ECO"
            if let violation = placedCellViolation(output.cells[index], in: output, excluding: target) {
                return blocked(
                    code: "eco_resize_illegal",
                    message: violation,
                    entity: target,
                    actions: ["choose_another_eco_target", "move_adjacent_cells", "increase_core_area"]
                )
            }
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
            guard !output.cells[index].locked else {
                return blocked(
                    code: "eco_locked_cell",
                    message: "ECO move cannot mutate locked cell \(target).",
                    entity: target,
                    actions: ["unlock_the_cell_or_choose_another_target"]
                )
            }
            let cell = output.cells[index]
            let (movedX, xOverflow) = cell.x.addingReportingOverflow(configuration.ecoDeltaX)
            let (movedY, yOverflow) = cell.y.addingReportingOverflow(configuration.ecoDeltaY)
            guard !xOverflow, !yOverflow else {
                return blocked(
                    code: "eco_move_overflow",
                    message: "ECO move would overflow the target cell coordinates.",
                    entity: target,
                    actions: ["reduce_eco_delta"]
                )
            }
            let moved = PhysicalDesignSnapshot.Rect(
                x: movedX,
                y: movedY,
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
            if let violation = placedCellViolation(output.cells[index], in: output, excluding: target) {
                return blocked(
                    code: "eco_move_illegal",
                    message: violation,
                    entity: target,
                    actions: ["reduce_eco_delta", "move_adjacent_cells"]
                )
            }
        case .bufferInsertion:
            guard let netID = configuration.ecoTargetNetID,
                  let netIndex = output.nets.firstIndex(where: { $0.id == netID }) else {
                return blocked(
                    code: "eco_target_net_missing",
                    message: "Buffer insertion requires an existing target net.",
                    actions: ["set_eco_target_net_id"]
                )
            }
            guard let core = output.core, !output.rows.isEmpty else {
                return blocked(
                    code: "eco_buffer_placement_context_missing",
                    message: "Buffer insertion requires core geometry and placement rows.",
                    actions: ["run_floorplan_before_buffer_insertion"]
                )
            }
            let bufferID = "eco_buf_\(netID)"
            let originalNet = output.nets[netIndex]
            guard originalNet.pinIDs.count >= 2 else {
                return blocked(
                    code: "eco_buffer_connectivity_insufficient",
                    message: "Buffer insertion requires a target net with at least a source and sink.",
                    entity: netID,
                    actions: ["repair_net_connectivity"]
                )
            }
            let pinByID = Dictionary(uniqueKeysWithValues: output.pins.map { ($0.id, $0) })
            let sourcePinID = originalNet.pinIDs.first(where: { pinByID[$0]?.direction.lowercased() == "output" }) ?? originalNet.pinIDs[0]
            let sinkPinIDs = originalNet.pinIDs.filter { $0 != sourcePinID }
            let branchNetID = "\(netID)_eco_branch"
            let inputPinID = "pin_\(bufferID)_A"
            let outputPinID = "pin_\(bufferID)_Y"
            if output.cells.contains(where: { $0.id == bufferID }) {
                guard output.nets.contains(where: { $0.id == branchNetID }),
                      output.pins.contains(where: { $0.id == inputPinID && $0.cellID == bufferID && $0.netID == netID }),
                      output.pins.contains(where: { $0.id == outputPinID && $0.cellID == bufferID && $0.netID == branchNetID }),
                      output.nets[netIndex].pinIDs == [sourcePinID, inputPinID],
                      output.nets.first(where: { $0.id == branchNetID })?.pinIDs == [outputPinID] + sinkPinIDs,
                      output.routes.contains(where: { $0.netID == netID }),
                      output.routes.contains(where: { $0.netID == branchNetID }) else {
                    return blocked(
                        code: "eco_buffer_existing_incomplete",
                        message: "The existing ECO buffer \(bufferID) does not have complete split-net connectivity and cannot be treated as a completed no-op.",
                        entity: netID,
                        actions: ["resume_from_the_last_immutable_revision", "repair_eco_connectivity"]
                    )
                }
                return completed(
                    output,
                    actions: ["run_timing_analysis", "run_drc"],
                    metrics: metrics(for: output),
                    note: "The requested ECO buffer and both routed branch nets already exist in the canonical snapshot."
                )
            }
            guard !output.nets.contains(where: { $0.id == branchNetID }) else {
                return blocked(
                    code: "eco_buffer_branch_exists",
                    message: "The target net already has the reserved ECO branch net \(branchNetID).",
                    entity: netID,
                    actions: ["resume_from_the_existing_eco_revision"]
                )
            }
            let location = output.pins.first(where: { $0.id == sourcePinID })
            guard let placement = legalBufferPlacement(
                near: location,
                core: core,
                rows: output.rows,
                cells: output.cells,
                blockages: output.blockages,
                width: configuration.siteWidth * 2,
                height: configuration.rowHeight
            ) else {
                return blocked(
                    code: "eco_buffer_placement_unavailable",
                    message: "No legal row location is available for the ECO buffer on net \(netID).",
                    entity: netID,
                    actions: ["increase_core_area", "move_blockages", "reduce_buffer_width"]
                )
            }
            output.cells.append(
                PhysicalDesignSnapshot.Cell(
                    id: bufferID,
                    master: "BUF_ECO",
                    x: placement.x,
                    y: placement.y,
                    width: configuration.siteWidth * 2,
                    height: configuration.rowHeight,
                    placed: true,
                    isClockBuffer: false
                )
            )
            let inputX = placement.x
            let inputY = placement.y + configuration.rowHeight / 2
            let outputX = placement.x + configuration.siteWidth * 2
            output.pins.append(PhysicalDesignSnapshot.Pin(
                id: inputPinID,
                cellID: bufferID,
                name: "A",
                x: inputX,
                y: inputY,
                netID: netID,
                direction: "input"
            ))
            output.pins.append(PhysicalDesignSnapshot.Pin(
                id: outputPinID,
                cellID: bufferID,
                name: "Y",
                x: outputX,
                y: inputY,
                netID: branchNetID,
                direction: "output"
            ))
            for index in output.pins.indices where sinkPinIDs.contains(output.pins[index].id) {
                output.pins[index].netID = branchNetID
            }
            output.nets[netIndex].pinIDs = [sourcePinID, inputPinID]
            output.nets.append(PhysicalDesignSnapshot.Net(
                id: branchNetID,
                pinIDs: [outputPinID] + sinkPinIDs,
                isClock: originalNet.isClock,
                antennaRatio: originalNet.antennaRatio,
                maximumAntennaRatio: originalNet.maximumAntennaRatio
            ))
            netsToRoute = [netID, branchNetID]
        case .rerouteNet:
            guard let netID = configuration.ecoTargetNetID,
                  output.nets.contains(where: { $0.id == netID }) else {
                return blocked(code: "eco_target_net_missing", message: "Reroute requires an existing target net.", actions: ["set_eco_target_net_id"])
            }
            let routingOutcome = routing(output, configuration: configuration, mode: "eco", onlyNetID: netID)
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
            guard !output.cells.contains(where: { cell in
                cell.placed && PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height).intersects(geometry)
            }) else {
                return blocked(
                    code: "eco_blockage_cell_conflict",
                    message: "ECO blockage candidate intersects a placed cell.",
                    actions: ["move_the_cell", "choose_a_different_repair_region"]
                )
            }
            output.blockages.append(geometry)
        }
        for netID in netsToRoute {
            let routingOutcome = routing(output, configuration: configuration, mode: "eco", onlyNetID: netID)
            guard let routed = routingOutcome.snapshot, routingOutcome.status == .completed else {
                return routingOutcome
            }
            output = routed
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
        var repairIDs: [String] = []
        for index in output.nets.indices {
            guard let ratio = output.nets[index].antennaRatio,
                  ratio > (output.nets[index].maximumAntennaRatio ?? configuration.maximumAntennaRatio) else { continue }
            let netID = output.nets[index].id
            guard routeNetIDs.contains(netID) else { continue }
            let limit = output.nets[index].maximumAntennaRatio ?? configuration.maximumAntennaRatio
            let resultingRatio = min(ratio, limit * 0.5)
            output.nets[index].antennaRatio = resultingRatio
            let strategy = repairConstraints.antennaStrategy.rawValue
            let repairID = "antenna_repair_\(netID)_\(output.antennaRepairs.filter { $0.netID == netID }.count + 1)"
            output.antennaRepairs.append(
                PhysicalDesignSnapshot.AntennaRepair(
                    id: repairID,
                    netID: netID,
                    strategy: strategy,
                    previousRatio: ratio,
                    resultingRatio: resultingRatio
                )
            )
            repairIDs.append(repairID)
            if let routeIndex = output.routes.firstIndex(where: { $0.netID == netID }),
               let last = output.routes[routeIndex].segments.last {
                switch repairConstraints.antennaStrategy {
                case .jumper:
                    guard let core = output.core else {
                        return blocked(code: "core_geometry_missing", message: "Antenna jumper repair requires a core rectangle.", actions: ["run_floorplan"])
                    }
                    let nextLayer = last.layer == Int.max ? Int.max : last.layer + 1
                    let layer = min(configuration.maximumRoutingLayer, nextLayer)
                    let (endX, overflow) = last.x2.addingReportingOverflow(configuration.siteWidth)
                    guard !overflow else {
                        return blocked(code: "antenna_jumper_overflow", message: "Antenna jumper geometry would overflow the coordinate range.", entity: netID, actions: ["reduce_jumper_length"])
                    }
                    let segment = PhysicalDesignSnapshot.RouteSegment(
                        id: "antenna_jumper_\(netID)_\(repaired)",
                        layer: layer,
                        x1: last.x2,
                        y1: last.y2,
                        x2: endX,
                        y2: last.y2,
                        isJumper: true
                    )
                    let geometry = segmentGeometry(segment, width: configuration.implementationConstraints?.routeWidth ?? PhysicalDesignImplementationConstraints.default.routeWidth)
                    guard core.contains(geometry), !output.blockages.contains(where: { $0.intersects(geometry) }) else {
                        return blocked(code: "antenna_jumper_illegal", message: "Antenna jumper candidate for net \(netID) leaves the core or intersects a blockage.", entity: netID, actions: ["move_the_blockage", "select_the_protection_device_strategy"])
                    }
                    output.routes[routeIndex].segments.append(segment)
                case .reroute:
                    guard let core = output.core else {
                        return blocked(code: "core_geometry_missing", message: "Antenna reroute repair requires a core rectangle.", actions: ["run_floorplan"])
                    }
                    let nextLayer = last.layer == Int.max ? Int.max : last.layer + 1
                    let layer = min(configuration.maximumRoutingLayer, nextLayer)
                    let (endY, overflow) = last.y2.addingReportingOverflow(configuration.siteWidth)
                    guard !overflow else {
                        return blocked(code: "antenna_reroute_overflow", message: "Antenna reroute geometry would overflow the coordinate range.", entity: netID, actions: ["reduce_reroute_length"])
                    }
                    let segment = PhysicalDesignSnapshot.RouteSegment(
                        id: "antenna_reroute_\(netID)_\(repaired)",
                        layer: layer,
                        x1: last.x2,
                        y1: last.y2,
                        x2: last.x2,
                        y2: endY
                    )
                    let geometry = segmentGeometry(segment, width: configuration.implementationConstraints?.routeWidth ?? PhysicalDesignImplementationConstraints.default.routeWidth)
                    guard core.contains(geometry), !output.blockages.contains(where: { $0.intersects(geometry) }) else {
                        return blocked(code: "antenna_reroute_illegal", message: "Antenna reroute candidate for net \(netID) leaves the core or intersects a blockage.", entity: netID, actions: ["move_the_blockage", "select_the_protection_device_strategy"])
                    }
                    output.routes[routeIndex].segments.append(segment)
                case .protectionDevice:
                    let protectionID = "antenna_protect_\(netID)"
                    guard let core = output.core, !output.rows.isEmpty else {
                        return blocked(code: "antenna_protection_placement_context_missing", message: "Antenna protection devices require core geometry and placement rows.", entity: netID, actions: ["run_floorplan", "run_placement"])
                    }
                    if !output.cells.contains(where: { $0.id == protectionID }) {
                        let width = max(configuration.siteWidth, configuration.siteWidth * 2)
                        guard let placement = legalBufferPlacement(
                            near: output.pins.first(where: { $0.netID == netID }),
                            core: core,
                            rows: output.rows,
                            cells: output.cells,
                            blockages: output.blockages,
                            width: width,
                            height: configuration.rowHeight
                        ) else {
                            return blocked(code: "antenna_protection_location_unavailable", message: "No legal placement row is available for the antenna protection device on net \(netID).", entity: netID, actions: ["move_the_blockage", "increase_core_area", "select_the_jumper_strategy"])
                        }
                        let geometry = PhysicalDesignSnapshot.Rect(x: placement.x, y: placement.y, width: width, height: configuration.rowHeight)
                        output.cells.append(PhysicalDesignSnapshot.Cell(
                            id: protectionID,
                            master: "ANTENNA_DIODE",
                            x: geometry.x,
                            y: geometry.y,
                            width: geometry.width,
                            height: geometry.height,
                            placed: true
                        ))
                    }
                    let pinID = "pin_\(protectionID)_A"
                    if !output.pins.contains(where: { $0.id == pinID }) {
                        guard let protection = output.cells.first(where: { $0.id == protectionID }) else {
                            return blocked(
                                code: "antenna_protection_cell_missing",
                                message: "The antenna protection device was selected but is missing from the canonical snapshot.",
                                entity: netID,
                                actions: ["repair_antenna_snapshot", "rerun_antenna_repair"]
                            )
                        }
                        output.pins.append(PhysicalDesignSnapshot.Pin(
                            id: pinID,
                            cellID: protectionID,
                            name: "A",
                            x: protection.x,
                            y: protection.y + protection.height / 2,
                            netID: netID,
                            direction: "input"
                        ))
                    }
                    if !output.nets[index].pinIDs.contains(pinID) {
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
            targetIDs: repairIDs,
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
            guard fillViolationCount(output, repairConstraints: repairConstraints) == 0 else {
                return blocked(
                    code: "existing_fill_invalid",
                    message: "Existing fill geometry violates native density, spacing or exclusion checks.",
                    actions: ["remove_invalid_fill", "rerun_fill_insertion"]
                )
            }
            return completed(
                output,
                actions: ["run_density_drc"],
                metrics: metrics(for: output),
                note: "Existing fill geometry already satisfies native checks; no new fill was inserted."
            )
        }
        let step = configuration.fillWindowSize + max(configuration.fillSpacing, repairConstraints.minimumFillSpacing)
        guard step > 0 else {
            return blocked(code: "invalid_fill_grid", message: "Fill grid step must be positive.", actions: ["correct_fill_configuration"])
        }
        let fillWidth = max(configuration.siteWidth, configuration.fillWindowSize / 4)
        let fillHeight = max(configuration.rowHeight, configuration.fillWindowSize / 4)
        var id = 0
        let fillOffset = max(configuration.fillSpacing, repairConstraints.minimumFillSpacing)
        let (initialY, initialYOverflow) = core.y.addingReportingOverflow(fillOffset)
        guard !initialYOverflow else {
            return blocked(code: "fill_geometry_overflow", message: "Fill insertion cannot establish a safe starting coordinate within the core.", actions: ["reduce_fill_spacing", "move_the_core_geometry"])
        }
        var y = initialY
        let maximumFillArea = Double(core.width) * Double(core.height) * repairConstraints.maximumFillDensity
        while true {
            if Task.isCancelled {
                return cancelled(actions: ["resume_from_the_last_immutable_revision"])
            }
            let (yEnd, yEndOverflow) = y.addingReportingOverflow(fillHeight)
            guard !yEndOverflow, yEnd <= core.maxY else { break }
            let (initialX, initialXOverflow) = core.x.addingReportingOverflow(fillOffset)
            guard !initialXOverflow else {
                return blocked(code: "fill_geometry_overflow", message: "Fill insertion cannot establish a safe starting coordinate within the core.", actions: ["reduce_fill_spacing", "move_the_core_geometry"])
            }
            var x = initialX
            while true {
                if Task.isCancelled {
                    return cancelled(actions: ["resume_from_the_last_immutable_revision"])
                }
                let (xEnd, xEndOverflow) = x.addingReportingOverflow(fillWidth)
                guard !xEndOverflow, xEnd <= core.maxX else { break }
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
                let (nextX, nextXOverflow) = x.addingReportingOverflow(step)
                guard !nextXOverflow else { break }
                x = nextX
            }
            let (nextY, nextYOverflow) = y.addingReportingOverflow(step)
            guard !nextYOverflow else { break }
            y = nextY
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
        guard let core = output.core else {
            return blocked(code: "core_geometry_missing", message: "Redundant-via insertion requires a core rectangle.", actions: ["run_floorplan"])
        }
        let repairConstraints = configuration.repairConstraints ?? .default
        guard viaViolationCount(output, minimumSpacing: repairConstraints.minimumViaSpacing) == 0 else {
            return blocked(
                code: "existing_via_spacing_invalid",
                message: "Existing via geometry already violates the native minimum spacing.",
                actions: ["repair_existing_via_spacing", "rerun_detailed_routing"]
            )
        }
        let existingIDs = Set(output.vias.map(\.id))
        let candidates = output.vias.filter {
            !$0.isRedundant
                && core.containsPoint(x: $0.x, y: $0.y)
                && $0.lowerLayer <= configuration.maximumRoutingLayer
                && $0.upperLayer <= configuration.maximumRoutingLayer
                && viaHasRouteConnection($0, snapshot: output)
        }
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
                let (x, xOverflow) = via.x.addingReportingOverflow(deltaX)
                let (y, yOverflow) = via.y.addingReportingOverflow(deltaY)
                guard !xOverflow, !yOverflow, core.containsPoint(x: x, y: y) else { return false }
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
            return blocked(
                code: "redundant_via_location_unavailable",
                message: "No legal redundant-via location satisfies core and spacing constraints.",
                actions: ["increase_via_spacing", "rerun_detailed_routing"]
            )
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
        guard output.core != nil else {
            return blocked(code: "core_geometry_missing", message: "Hotspot repair requires a core rectangle.", actions: ["run_floorplan"])
        }
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
    ) -> DesignDiagnostic? {
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
        count += commonPhysicalViolationCount(snapshot)
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

    private func commonPhysicalViolationCount(_ snapshot: PhysicalDesignSnapshot) -> Int {
        var count = 0
        let placedCells = snapshot.cells.filter(\.placed)
        let geometries = placedCells.map {
            PhysicalDesignSnapshot.Rect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        for leftIndex in geometries.indices {
            for rightIndex in geometries.indices where rightIndex > leftIndex {
                if geometries[leftIndex].intersects(geometries[rightIndex]) {
                    count += 1
                }
            }
        }
        if let core = snapshot.core {
            count += placedCells.reduce(into: 0) { result, cell in
                let geometry = PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)
                if !core.contains(geometry) {
                    result += 1
                }
            }
        }
        count += placedCells.reduce(into: 0) { result, cell in
            let geometry = PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)
            if snapshot.blockages.contains(where: { $0.intersects(geometry) }) {
                result += 1
            }
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

    private func viaHasRouteConnection(
        _ via: PhysicalDesignSnapshot.Via,
        snapshot: PhysicalDesignSnapshot
    ) -> Bool {
        snapshot.routes
            .filter { $0.netID == via.netID }
            .flatMap(\.segments)
            .contains { segment in
                guard segment.layer == via.lowerLayer || segment.layer == via.upperLayer else { return false }
                if segment.y1 == segment.y2 {
                    return via.y == segment.y1 && via.x >= min(segment.x1, segment.x2) && via.x <= max(segment.x1, segment.x2)
                }
                return via.x == segment.x1 && via.y >= min(segment.y1, segment.y2) && via.y <= max(segment.y1, segment.y2)
            }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func legalBufferPlacement(
        near pin: PhysicalDesignSnapshot.Pin?,
        core: PhysicalDesignSnapshot.Rect,
        rows: [PhysicalDesignSnapshot.Row],
        cells: [PhysicalDesignSnapshot.Cell],
        blockages: [PhysicalDesignSnapshot.Rect],
        width: Int64,
        height: Int64
    ) -> (x: Int64, y: Int64)? {
        guard width > 0, height > 0 else { return nil }
        let edgeClearance = max(1, width / 2)
        let targetX = pin?.x ?? core.x
        for row in rows.sorted(by: { $0.id < $1.id }) where height <= row.height {
            let rowEnd = min(row.originX + row.siteCount * row.siteWidth, core.maxX)
            let maximumX = rowEnd - width
            guard maximumX >= row.originX else { continue }
            let rawStart = max(row.originX, min(maximumX, targetX))
            let alignedStart = row.originX + max(0, rawStart - row.originX + row.siteWidth - 1) / row.siteWidth * row.siteWidth
            let candidates = [
                alignedStart,
                row.originX,
                maximumX
            ] + stride(
                from: row.originX,
                through: maximumX,
                by: Int(exactly: max(Int64(1), row.siteWidth)) ?? 1
            ).filter {
                abs($0 - targetX) <= max(core.width, core.height)
            }
            for x in candidates where x >= row.originX && x <= maximumX {
                let geometry = PhysicalDesignSnapshot.Rect(x: x, y: row.originY, width: width, height: height)
                guard core.contains(geometry.expanded(by: edgeClearance)), !blockages.contains(where: { $0.intersects(geometry) }) else { continue }
                guard !cells.contains(where: { cell in
                    cell.placed && PhysicalDesignSnapshot.Rect(
                        x: cell.x,
                        y: cell.y,
                        width: cell.width,
                        height: cell.height
                    ).intersects(geometry)
                }) else { continue }
                return (x, row.originY)
            }
        }
        return nil
    }

    private func placedCellViolation(
        _ cell: PhysicalDesignSnapshot.Cell,
        in snapshot: PhysicalDesignSnapshot,
        excluding excludedCellID: String
    ) -> String? {
        guard cell.placed else { return nil }
        let geometry = PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)
        if let core = snapshot.core, !core.contains(geometry) {
            return "Cell \(cell.id) is outside the core rectangle."
        }
        if snapshot.blockages.contains(where: { $0.intersects(geometry) }) {
            return "Cell \(cell.id) intersects a placement blockage."
        }
        if snapshot.cells.contains(where: { other in
            other.id != excludedCellID
                && other.id != cell.id
                && other.placed
                && PhysicalDesignSnapshot.Rect(x: other.x, y: other.y, width: other.width, height: other.height).intersects(geometry)
        }) {
            return "Cell \(cell.id) overlaps another placed cell."
        }
        return nil
    }

    private func padSide(for pin: PhysicalDesignSnapshot.Pin, die: PhysicalDesignSnapshot.Rect) -> String {
        let distances: [(String, Int64)] = [
            ("left", absoluteDifference(pin.x, die.x)),
            ("right", absoluteDifference(die.maxX, pin.x)),
            ("bottom", absoluteDifference(pin.y, die.y)),
            ("top", absoluteDifference(die.maxY, pin.y))
        ]
        return distances.min { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }?.0 ?? "left"
    }

    private func padGeometry(
        for pin: PhysicalDesignSnapshot.Pin,
        side: String,
        die: PhysicalDesignSnapshot.Rect,
        configuration: PhysicalDesignConfiguration
    ) -> PhysicalDesignSnapshot.Rect {
        let width = min(max(configuration.siteWidth, configuration.rowHeight / 2), die.width)
        let height = min(max(configuration.siteWidth, configuration.rowHeight / 2), die.height)
        let boundedX = max(die.x, min(pin.x, die.maxX - width))
        let boundedY = max(die.y, min(pin.y, die.maxY - height))
        switch side {
        case "right":
            return PhysicalDesignSnapshot.Rect(x: die.maxX - width, y: boundedY, width: width, height: height)
        case "bottom":
            return PhysicalDesignSnapshot.Rect(x: boundedX, y: die.y, width: width, height: height)
        case "top":
            return PhysicalDesignSnapshot.Rect(x: boundedX, y: die.maxY - height, width: width, height: height)
        default:
            return PhysicalDesignSnapshot.Rect(x: die.x, y: boundedY, width: width, height: height)
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
            let usedWidth = snapshot.cells
                .filter { $0.placed && $0.y == row.originY }
                .reduce(0.0) { $0 + Double($1.width) }
            let capacity = max(1.0, Double(row.siteCount) * Double(row.siteWidth))
            return max(maximum, usedWidth / capacity)
        }
    }

    private func completed(
        _ snapshot: PhysicalDesignSnapshot,
        diagnostics: [DesignDiagnostic] = [],
        actions: [String],
        metrics: [PhysicalDesignMetric],
        note: String? = nil
    ) -> Outcome {
        var allDiagnostics = diagnostics
        if let note {
            allDiagnostics.append(diagnostic(severity: .information, code: "execution_note", message: note, actions: []))
        }
        return Outcome(snapshot: snapshot, status: .completed, diagnostics: allDiagnostics, candidateActions: actions, metrics: metrics)
    }

    private func cancelled(actions: [String]) -> Outcome {
        Outcome(
            snapshot: nil,
            status: .cancelled,
            diagnostics: [diagnostic(
                severity: .warning,
                code: "execution_cancelled",
                message: "Physical design mutation was cancelled before an immutable revision was committed.",
                actions: actions
            )],
            candidateActions: actions
        )
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
        severity: DiagnosticSeverity,
        code: String,
        message: String,
        entity: String? = nil,
        actions: [String]
    ) -> DesignDiagnostic {
        DesignDiagnostic(severity: severity, code: code, message: message, entity: entity, suggestedActions: actions)
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
        cells _: [String: PhysicalDesignSnapshot.Cell]
    ) -> (x: Int64, y: Int64) {
        return (pin.x, pin.y)
    }

    private func absoluteDifference(_ left: Int64, _ right: Int64) -> Int64 {
        let (difference, overflow) = left.subtractingReportingOverflow(right)
        guard !overflow else { return .max }
        return difference == .min ? .max : abs(difference)
    }

    private func saturatedSubtract(_ value: Int64, _ amount: Int64) -> Int64 {
        let (result, overflow) = value.subtractingReportingOverflow(amount)
        return overflow ? .min : result
    }

    private func manhattan(_ x1: Int64, _ y1: Int64, _ x2: Int64, _ y2: Int64) -> Int64 {
        let xDistance = absoluteDifference(x1, x2)
        let yDistance = absoluteDifference(y1, y2)
        let (distance, overflow) = xDistance.addingReportingOverflow(yDistance)
        return overflow ? .max : distance
    }

    private func midpoint(_ left: Int64, _ right: Int64) -> Int64 {
        let (difference, overflow) = right.subtractingReportingOverflow(left)
        guard !overflow else {
            return left >= 0 && right >= 0 ? Int64.max / 2 : Int64.min / 2
        }
        return left + difference / 2
    }
}
