import Foundation

public struct PhysicalDesignDEFWriter: Sendable {
    public init() {}

    public func write(_ snapshot: PhysicalDesignSnapshot) -> String {
        let die = snapshot.die ?? PhysicalDesignSnapshot.Rect(x: 0, y: 0, width: 1, height: 1)
        let sortedCells = snapshot.cells.sorted { $0.id < $1.id }
        let sortedNets = snapshot.nets.sorted { $0.id < $1.id }
        var lines: [String] = [
            "VERSION 5.8 ;",
            "DIVIDERCHAR \"/\" ;",
            "BUSBITCHARS \"[]\" ;",
            "DESIGN \(snapshot.topCell) ;",
            "UNITS DISTANCE MICRONS \(snapshot.unitsPerMicron) ;",
            "DIEAREA ( \(die.x) \(die.y) ) ( \(die.maxX) \(die.maxY) ) ;",
            "COMPONENTS \(sortedCells.count) ;"
        ]
        for row in snapshot.rows.sorted(by: { $0.id < $1.id }) {
            lines.insert(
                "ROW \(row.id) coreSite \(row.originX) \(row.originY) N DO \(max(1, row.siteCount)) BY 1 STEP \(row.siteWidth) \(row.height) ;",
                at: lines.count - 1
            )
        }
        for cell in sortedCells {
            let placement = cell.placed ? "PLACED" : "UNPLACED"
            lines.append("- \(cell.id) \(cell.master) + \(placement) ( \(cell.x) \(cell.y) ) N ;")
        }
        lines.append("END COMPONENTS")
        lines.append("NETS \(sortedNets.count) ;")
        let pinByID = Dictionary(uniqueKeysWithValues: snapshot.pins.map { ($0.id, $0) })
        for net in sortedNets {
            let pinNames = net.pinIDs.sorted().compactMap { pinByID[$0] }.map { pin in
                "( \(pin.cellID ?? "PIN") \(pin.name) )"
            }.joined(separator: " ")
            lines.append("- \(net.id) \(pinNames) ;")
        }
        lines.append("END NETS")
        lines.append("END DESIGN")
        return lines.joined(separator: "\n") + "\n"
    }
}
