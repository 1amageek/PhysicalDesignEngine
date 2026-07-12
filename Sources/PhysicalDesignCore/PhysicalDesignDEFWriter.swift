import Foundation

public struct PhysicalDesignDEFWriter: Sendable {
    public init() {}

    public func write(_ snapshot: PhysicalDesignSnapshot) -> String {
        let die = snapshot.die ?? PhysicalDesignSnapshot.Rect(x: 0, y: 0, width: 1, height: 1)
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
            lines.append("ROW \(row.id) coreSite \(row.originX) \(row.originY) N DO \(max(1, row.siteCount)) BY 1 STEP \(row.siteWidth) \(row.height) ;")
        }
        for track in snapshot.implementationState?.tracks.sorted(by: { $0.id < $1.id }) ?? [] {
            let axis = track.direction.lowercased() == "vertical" ? "X" : "Y"
            lines.append("TRACKS \(axis) \(track.origin) DO \(track.count) STEP \(track.spacing) LAYER M\(track.layer) ;")
        }
        lines.append(contentsOf: [
            "COMPONENTS \(sortedCells.count) ;"
        ])
        for cell in sortedCells {
            let placement = cell.placed ? "PLACED" : "UNPLACED"
            lines.append("- \(cell.id) \(cell.master) + \(placement) ( \(cell.x) \(cell.y) ) N + PROPERTY XCI_CELL_WIDTH \"\(cell.width)\" + PROPERTY XCI_CELL_HEIGHT \"\(cell.height)\" ;")
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
