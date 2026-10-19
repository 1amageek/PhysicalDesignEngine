import LayoutIR
import MaskGeometry

extension PhysicalDesignProcessGeometry {
    func redundantContactConnected(_ via: PhysicalDesignSnapshot.Via, snapshot: PhysicalDesignSnapshot,
        checks: inout Int, maximumChecks: Int?, minimumSpacing: Int64 = 0) throws -> Bool {
        guard let master = via.master else { throw PhysicalDesignTechnologyError.invalid("Redundant contact requires its exact master.") }
        let shapes = try viaShapes(master: master, x: via.x, y: via.y)
        for layer in [via.lowerLayer, via.upperLayer] {
            guard let native = Int16(exactly: layer) else { throw PhysicalDesignTechnologyError.invalid("Contact layer exceeds backend range.") }
            let metal = Region(layer: native, polygons: shapes.filter { $0.layer == native })
            var connected = false
            func intersects(_ other: Region) throws -> Bool {
                try Task.checkCancellation()
                let next = checks.addingReportingOverflow(1)
                guard !next.overflow, maximumChecks == nil || next.partialValue <= maximumChecks! else {
                    throw PhysicalDesignTechnologyError.invalid("Redundant contact geometry check ceiling exhausted.")
                }
                checks = next.partialValue
                return try !metal.intersection(other).isEmpty
            }
            for route in snapshot.routes where route.netID == via.netID {
                for segment in route.segments where segment.layer == layer {
                    guard let width = segment.widthDBU else { throw PhysicalDesignTechnologyError.unsupported("Contact connectivity requires exact conductor width.") }
                    if try intersects(PhysicalDesignSourceRouter.conductor(segment, width: width)) { connected = true }
                }
            }
            for pin in snapshot.pins where pin.netID == via.netID {
                if let cellID = pin.cellID, let cell = snapshot.cells.first(where: { $0.id == cellID }) {
                    let ports = try pinShapes(master: cell.master, pin: pin.name, orientation: cell.orientation, x: cell.x, y: cell.y)
                    if try intersects(Region(layer: native, polygons: ports.filter { $0.layer == native })) { connected = true }
                } else if let port = pin.topPort, port.layer == layer {
                    if try intersects(PhysicalDesignSourceRouter.rectangle(port.worldRectangle(), layer: layer)) { connected = true }
                }
            }
            guard connected else { return false }
            let sourceSpacing = try sourceLayers[native]?.spacing.map {
                try PhysicalDesignProcessInputs.dbu($0, units: snapshot.unitsPerMicron, field: "contact metal SPACING")
            }
            let clearance = max(minimumSpacing, sourceSpacing ?? 0)
            guard let spacing = Int32(exactly: clearance) else { throw PhysicalDesignTechnologyError.invalid("Contact clearance exceeds backend range.") }
            func excludes(_ other: Region, useSpacing: Bool = true) throws -> Bool {
                if try intersects(other) { return true }
                if useSpacing && spacing > 0 {
                    try Task.checkCancellation()
                    return try !metal.spaceViolations(to: other, minSpace: spacing).isEmpty
                }
                return false
            }
            for rect in snapshot.blockages {
                if try excludes(PhysicalDesignSourceRouter.rectangle(rect, layer: layer), useSpacing: false) { return false }
            }
            for cell in snapshot.cells {
                for shape in try obstructionShapes(master: cell.master, orientation: cell.orientation, x: cell.x, y: cell.y) where shape.layer == native {
                    if try excludes(Region(layer: native, polygons: [shape])) { return false }
                }
                for name in try requireMaster(cell.master).pins.keys.sorted() {
                    if snapshot.pins.contains(where: { $0.cellID == cell.id && $0.name == name && $0.netID == via.netID }) { continue }
                    for shape in try pinShapes(master: cell.master, pin: name, orientation: cell.orientation, x: cell.x, y: cell.y) where shape.layer == native {
                        if try excludes(Region(layer: native, polygons: [shape])) { return false }
                    }
                }
            }
            for route in snapshot.routes where route.netID != via.netID {
                for segment in route.segments where segment.layer == layer {
                    guard let width = segment.widthDBU else { throw PhysicalDesignTechnologyError.unsupported("Contact clearance requires actual conductor width.") }
                    if try excludes(PhysicalDesignSourceRouter.conductor(segment, width: width)) { return false }
                }
            }
            for fill in snapshot.fills where fill.layer == layer {
                if try excludes(PhysicalDesignSourceRouter.rectangle(fill.geometry, layer: layer)) { return false }
            }
            for existing in snapshot.vias where existing.netID != via.netID {
                guard let name = existing.master else { throw PhysicalDesignTechnologyError.unsupported("Contact clearance requires source fixed contacts.") }
                let metal = try viaShapes(master: name, x: existing.x, y: existing.y).filter { $0.layer == native }
                if try excludes(Region(layer: native, polygons: metal)) { return false }
            }
        }
        return true
    }
}
