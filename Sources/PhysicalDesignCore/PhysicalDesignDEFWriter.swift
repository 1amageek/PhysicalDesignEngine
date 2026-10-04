import Foundation

public struct PhysicalDesignDEFWriter: Sendable {
    public init() {}

    public func write(_ snapshot: PhysicalDesignSnapshot) throws -> String {
        try write(snapshot, processGeometry: nil)
    }

    func write(_ snapshot: PhysicalDesignSnapshot, processGeometry: PhysicalDesignProcessGeometry?, maximumOutputByteCount: UInt64? = nil) throws -> String {
        let issues = snapshot.validationDiagnostics()
        guard issues.isEmpty, let die = snapshot.die else {
            throw PhysicalDesignDEFExportError.invalidSnapshot(issues.isEmpty ? "DEF export requires explicit die geometry." : issues.joined(separator: "; "))
        }
        if snapshot.processManifest != nil {
            // Mutation already admitted this output; export checks identity and loss without repeating shape projection.
            guard let processGeometry, snapshot.processManifest == processGeometry.manifestReference,
                  snapshot.processAssets == processGeometry.sources else { throw PhysicalDesignDEFExportError.unresolvedProcessSources }
            // FIXME(INCOMPLETE_IMPLEMENTATION): Source-bound top-level PORT and special-net geometry require exact standard interchange. API/CLI export must reject those profiles until their geometry is represented without loss.
            guard snapshot.powerStructures.isEmpty, snapshot.pins.allSatisfy({ $0.cellID != nil }) else {
                throw PhysicalDesignDEFExportError.unsupportedProcessGeometry("Top-port and special-net DEF interchange is not complete.")
            }
            for route in snapshot.routes {
                for segment in route.segments {
                    guard let width = segment.widthDBU else { throw PhysicalDesignDEFExportError.unsupportedProcessGeometry("Normal-net conductor width is unqualified.") }
                    do {
                        _ = try processGeometry.routingWidthAndSpacing(layer: segment.layer, units: snapshot.unitsPerMicron, width: width)
                        _ = try PhysicalDesignSourceRouter.conductor(segment, width: width)
                    } catch let error as PhysicalDesignRoutingSourceError {
                        throw PhysicalDesignDEFExportError.unsupportedProcessGeometry(error.message)
                    } catch let error as PhysicalDesignSourceRouter.Failure {
                        throw PhysicalDesignDEFExportError.invalidSnapshot(error.message)
                    }
                }
            }
            for via in snapshot.vias {
                guard via.master != nil else { throw PhysicalDesignDEFExportError.unsupportedProcessGeometry("Contact master is unqualified.") }
                _ = try processGeometry.resolveVia(via, within: die)
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
        var text = PhysicalDesignDEFText(limit: maximumOutputByteCount)
        for line in [
            "VERSION 5.8 ;",
            "DIVIDERCHAR \"/\" ;",
            "BUSBITCHARS \"[]\" ;",
            "DESIGN \(snapshot.topCell) ;",
            "UNITS DISTANCE MICRONS \(snapshot.unitsPerMicron) ;",
            "DIEAREA ( \(die.x) \(die.y) ) ( \(die.maxX) \(die.maxY) ) ;"
        ] { try text.line(line) }
        for row in sortedRows {
            // FIXME(INCOMPLETE_IMPLEMENTATION): Unqualified smoke rows have no LEF site source. The explicit smoke STEP-y height is retained until every such caller supplies a standard site definition; it does not prove process correctness.
            let stepY = processGeometry == nil ? row.height : 0
            try text.line("ROW \(row.id) \(row.siteName ?? "coreSite") \(row.originX) \(row.originY) \(row.orientation.rawValue) DO \(row.siteCount) BY 1 STEP \(row.siteWidth) \(stepY) ;")
        }
        for track in snapshot.implementationState?.tracks.sorted(by: { $0.id < $1.id }) ?? [] {
            let axis = track.direction.lowercased() == "vertical" ? "X" : "Y"
            try text.line("TRACKS \(axis) \(track.origin) DO \(track.count) STEP \(track.spacing) LAYER \(try layerName(track.layer)) ;")
        }
        try text.line("COMPONENTS \(sortedCells.count) ;")
        for cell in sortedCells {
            let placement = cell.placed ? (cell.locked ? "FIXED" : "PLACED") : "UNPLACED"
            let location = cell.placed ? " ( \(cell.x) \(cell.y) ) \(cell.orientation.rawValue)" : ""
            let dimensions = processGeometry == nil ? " + PROPERTY XCI_CELL_WIDTH \"\(cell.width)\" + PROPERTY XCI_CELL_HEIGHT \"\(cell.height)\"" : ""
            try text.line("- \(cell.id) \(cell.master) + \(placement)\(location)\(dimensions) ;")
        }
        try text.line("END COMPONENTS")

        if !topPins.isEmpty {
            try text.line("PINS \(topPins.count) ;")
            let padByPinID = Dictionary(uniqueKeysWithValues: (snapshot.implementationState?.pads ?? []).map { ($0.pinID, $0) })
            for pin in topPins {
                let net = pin.netID ?? "UNCONNECTED"
                let direction = pin.direction.uppercased()
                var line = "- \(pin.name) + NET \(net) + DIRECTION \(direction) + USE SIGNAL + PLACED ( \(pin.x) \(pin.y) ) N"
                if let pad = padByPinID[pin.id] {
                    line += " + PROPERTY XCI_PAD_SIDE \"\(pad.side)\" + PROPERTY XCI_PAD_X \(pad.geometry.x) + PROPERTY XCI_PAD_Y \(pad.geometry.y) + PROPERTY XCI_PAD_WIDTH \(pad.geometry.width) + PROPERTY XCI_PAD_HEIGHT \(pad.geometry.height)"
                }
                try text.line(line + " ;")
            }
            try text.line("END PINS")
        }

        try text.line("NETS \(sortedNets.count) ;")
        let pinByID = Dictionary(uniqueKeysWithValues: snapshot.pins.map { ($0.id, $0) })
        let routesByNet = Dictionary(grouping: snapshot.routes, by: \.netID)
        for net in sortedNets {
            try text.append("- \(net.id) ")
            var separator = ""
            for pinID in net.pinIDs.sorted() {
                guard let pin = pinByID[pinID] else { continue }
                try text.append(separator)
                try text.append("( \(pin.cellID ?? "PIN") \(pin.name) )")
                separator = " "
            }
            if net.isClock { try text.append(" + USE CLOCK") }
            for route in routesByNet[net.id, default: []].sorted(by: { $0.id < $1.id }) {
                for segment in route.segments.sorted(by: { $0.id < $1.id }) {
                    try text.append(" + ROUTED \(try layerName(segment.layer)) ( \(segment.x1) \(segment.y1) ) ( \(segment.x2) \(segment.y2) )")
                }
            }
            // FIXME(INCOMPLETE_IMPLEMENTATION): Source-free smoke has no fixed contact declaration and cannot qualify routed DEF contact semantics. Exact contact emission belongs to the source-bound profile.
            for via in (processGeometry == nil ? [] : snapshot.vias.filter({ $0.netID == net.id })).sorted(by: { $0.id < $1.id }) {
                guard let master = via.master else { throw PhysicalDesignDEFExportError.unsupportedProcessGeometry("Fixed contact export requires its exact master name.") }
                try text.append(" + ROUTED \(try layerName(via.lowerLayer)) ( \(via.x) \(via.y) ) \(master)")
            }
            try text.line(" ;")
        }
        try text.line("END NETS")

        if !sortedBlockages.isEmpty {
            try text.line("BLOCKAGES \(sortedBlockages.count) ;")
            for blockage in sortedBlockages {
                try text.line("- PLACEMENT RECT ( \(blockage.x) \(blockage.y) ) ( \(blockage.maxX) \(blockage.maxY) ) ;")
            }
            try text.line("END BLOCKAGES")
        }

        if !sortedPowerStructures.isEmpty {
            try text.line("SPECIALNETS \(sortedPowerStructures.count) ;")
            for structure in sortedPowerStructures {
                try text.line("- \(structure.netID) + USE \(structure.kind.uppercased()) + PROPERTY XCI_POWER_ID \"\(structure.id)\" + ROUTED M\(structure.layer) 0 ( \(structure.geometry.x) \(structure.geometry.y) ) ( \(structure.geometry.maxX) \(structure.geometry.maxY) ) ;")
            }
            try text.line("END SPECIALNETS")
        }

        try text.line("END DESIGN")
        return text.value
    }
}
