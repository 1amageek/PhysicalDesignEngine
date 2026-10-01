import Foundation

public struct PhysicalDesignDEFWriter: Sendable {
    public init() {}

    public func write(_ snapshot: PhysicalDesignSnapshot) throws -> String {
        try write(snapshot, processGeometry: nil)
    }

    func write(_ snapshot: PhysicalDesignSnapshot, processGeometry: PhysicalDesignProcessGeometry?) throws -> String {
        let issues = snapshot.validationDiagnostics()
        guard issues.isEmpty, let die = snapshot.die else {
            throw PhysicalDesignDEFExportError.invalidSnapshot(issues.isEmpty ? "DEF export requires explicit die geometry." : issues.joined(separator: "; "))
        }
        if snapshot.processManifest != nil {
            // Mutation already admitted this output; export checks identity and loss without repeating shape projection.
            guard let processGeometry, snapshot.processManifest == processGeometry.manifestReference,
                  snapshot.processAssets == processGeometry.sources else { throw PhysicalDesignDEFExportError.unresolvedProcessSources }
            // FIXME(INCOMPLETE_IMPLEMENTATION): Native process-bound DEF output currently preserves floorplan/cell geometry and connectivity only. Routed metal/vias, top-level port shapes and special nets need exact standard interchange before this API/CLI path may export them successfully.
            guard snapshot.routes.isEmpty, snapshot.vias.isEmpty, snapshot.powerStructures.isEmpty,
                  snapshot.pins.allSatisfy({ $0.cellID != nil }) else {
                throw PhysicalDesignDEFExportError.unsupportedProcessGeometry("Exact routed/via/top-port/special-net DEF interchange is not complete.")
            }
        }
        func layerName(_ number: Int) throws -> String {
            guard let processGeometry else { return "M\(number)" }
            guard let native = Int16(exactly: number), let definition = processGeometry.layers[native] else {
                throw PhysicalDesignDEFExportError.invalidSnapshot("Layer \(number) has no exact process mapping.")
            }
            return definition.name
        }
        let sortedRows = snapshot.rows.sorted { $0.id < $1.id }
        let sortedCells = snapshot.cells.sorted { $0.id < $1.id }
        let topPins = snapshot.pins.filter { $0.cellID == nil }.sorted { $0.id < $1.id }
        let sortedNets = snapshot.nets.sorted { $0.id < $1.id }
        let sortedBlockages = snapshot.blockages.sorted { lhs, rhs in
            (lhs.x, lhs.y, lhs.width, lhs.height) < (rhs.x, rhs.y, rhs.width, rhs.height)
        }
        let sortedPowerStructures = snapshot.powerStructures.sorted { $0.id < $1.id }
        var lines: [String] = [
            "VERSION 5.8 ;",
            "DIVIDERCHAR \"/\" ;",
            "BUSBITCHARS \"[]\" ;",
            "DESIGN \(snapshot.topCell) ;",
            "UNITS DISTANCE MICRONS \(snapshot.unitsPerMicron) ;",
            "DIEAREA ( \(die.x) \(die.y) ) ( \(die.maxX) \(die.maxY) ) ;"
        ]
        for row in sortedRows {
            // FIXME(INCOMPLETE_IMPLEMENTATION): Unqualified smoke rows have no LEF site source. The explicit smoke STEP-y height is retained until every such caller supplies a standard site definition; it does not prove process correctness.
            let stepY = processGeometry == nil ? row.height : 0
            lines.append("ROW \(row.id) \(row.siteName ?? "coreSite") \(row.originX) \(row.originY) \(row.orientation.rawValue) DO \(row.siteCount) BY 1 STEP \(row.siteWidth) \(stepY) ;")
        }
        for track in snapshot.implementationState?.tracks.sorted(by: { $0.id < $1.id }) ?? [] {
            let axis = track.direction.lowercased() == "vertical" ? "X" : "Y"
            lines.append("TRACKS \(axis) \(track.origin) DO \(track.count) STEP \(track.spacing) LAYER \(try layerName(track.layer)) ;")
        }
        lines.append(contentsOf: [
            "COMPONENTS \(sortedCells.count) ;"
        ])
        for cell in sortedCells {
            let placement = cell.placed ? (cell.locked ? "FIXED" : "PLACED") : "UNPLACED"
            let location = cell.placed ? " ( \(cell.x) \(cell.y) ) \(cell.orientation.rawValue)" : ""
            let dimensions = processGeometry == nil ? " + PROPERTY XCI_CELL_WIDTH \"\(cell.width)\" + PROPERTY XCI_CELL_HEIGHT \"\(cell.height)\"" : ""
            lines.append("- \(cell.id) \(cell.master) + \(placement)\(location)\(dimensions) ;")
        }
        lines.append("END COMPONENTS")

        if !topPins.isEmpty {
            lines.append("PINS \(topPins.count) ;")
            let padByPinID = Dictionary(uniqueKeysWithValues: (snapshot.implementationState?.pads ?? []).map { ($0.pinID, $0) })
            for pin in topPins {
                let net = pin.netID ?? "UNCONNECTED"
                let direction = pin.direction.uppercased()
                var line = "- \(pin.name) + NET \(net) + DIRECTION \(direction) + USE SIGNAL + PLACED ( \(pin.x) \(pin.y) ) N"
                if let pad = padByPinID[pin.id] {
                    line += " + PROPERTY XCI_PAD_SIDE \"\(pad.side)\" + PROPERTY XCI_PAD_X \(pad.geometry.x) + PROPERTY XCI_PAD_Y \(pad.geometry.y) + PROPERTY XCI_PAD_WIDTH \(pad.geometry.width) + PROPERTY XCI_PAD_HEIGHT \(pad.geometry.height)"
                }
                lines.append(line + " ;")
            }
            lines.append("END PINS")
        }

        lines.append("NETS \(sortedNets.count) ;")
        let pinByID = Dictionary(uniqueKeysWithValues: snapshot.pins.map { ($0.id, $0) })
        let routesByNet = Dictionary(grouping: snapshot.routes, by: \.netID)
        for net in sortedNets {
            let pinNames = net.pinIDs.sorted().compactMap { pinByID[$0] }.map { pin in
                "( \(pin.cellID ?? "PIN") \(pin.name) )"
            }.joined(separator: " ")
            var line = "- \(net.id) \(pinNames)"
            for route in routesByNet[net.id, default: []].sorted(by: { $0.id < $1.id }) {
                for segment in route.segments.sorted(by: { $0.id < $1.id }) {
                    line += " + ROUTED M\(segment.layer) 0 ( \(segment.x1) \(segment.y1) ) ( \(segment.x2) \(segment.y2) )"
                }
            }
            lines.append(line + " ;")
        }
        lines.append("END NETS")

        if !sortedBlockages.isEmpty {
            lines.append("BLOCKAGES \(sortedBlockages.count) ;")
            for blockage in sortedBlockages {
                lines.append("- PLACEMENT ( \(blockage.x) \(blockage.y) ) ( \(blockage.maxX) \(blockage.maxY) ) ;")
            }
            lines.append("END BLOCKAGES")
        }

        if !sortedPowerStructures.isEmpty {
            lines.append("SPECIALNETS \(sortedPowerStructures.count) ;")
            for structure in sortedPowerStructures {
                lines.append("- \(structure.netID) + USE \(structure.kind.uppercased()) + PROPERTY XCI_POWER_ID \"\(structure.id)\" + ROUTED M\(structure.layer) 0 ( \(structure.geometry.x) \(structure.geometry.y) ) ( \(structure.geometry.maxX) \(structure.geometry.maxY) ) ;")
            }
            lines.append("END SPECIALNETS")
        }

        lines.append("END DESIGN")
        return lines.joined(separator: "\n") + "\n"
    }
}
