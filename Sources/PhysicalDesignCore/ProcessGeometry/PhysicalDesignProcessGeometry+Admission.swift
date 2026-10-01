import DEF
import LEF
import LayoutIR
import MaskGeometry

extension PhysicalDesignProcessGeometry {
    func bind(_ snapshot: PhysicalDesignSnapshot) throws -> PhysicalDesignSnapshot {
        if snapshot.processManifest != nil || !snapshot.processAssets.isEmpty {
            guard snapshot.processManifest == manifestReference, snapshot.processAssets == sources else {
                throw PhysicalDesignTechnologyError.invalid("A process-bound snapshot requires the same manifest and complete asset-ID/reference map.")
            }
        }
        var bound = snapshot
        bound.processManifest = manifestReference
        bound.processAssets = sources
        return bound
    }

    func floorplanSite(for snapshot: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration) throws -> String {
        let names = try Set(snapshot.cells.map { cell -> String in
            let master = try requireMaster(cell.master)
            guard let name = master.definition.site else {
                throw PhysicalDesignTechnologyError.invalid("Core master \(cell.master) requires an explicit site.")
            }
            return name
        })
        let candidates = names.isEmpty ? sites.keys.sorted() : names.sorted()
        guard candidates.count == 1, let name = candidates.first, let site = sites[name],
              site.definition.siteClass == .core,
              configuration.siteWidth == site.width, configuration.rowHeight == site.height else {
            throw PhysicalDesignTechnologyError.invalid("Floorplan requires one explicit CORE site with configuration dimensions matching its exact SIZE.")
        }
        return name
    }

    func validate(_ snapshot: PhysicalDesignSnapshot, requirePlacementRows: Bool = true) throws {
        guard snapshot.validationDiagnostics().isEmpty,
              snapshot.processManifest == manifestReference, snapshot.processAssets == sources else {
            throw PhysicalDesignTechnologyError.invalid("Process admission requires a valid snapshot bound to the exact selected sources.")
        }
        let cells = Dictionary(uniqueKeysWithValues: snapshot.cells.map { ($0.id, $0) })
        let rowsByY = Dictionary(grouping: snapshot.rows, by: \.originY)
        var instancePins: [String: [String: [IRBoundary]]] = [:]
        for bounds in [snapshot.die, snapshot.core].compactMap({ $0 }) { try Self.validateBounds(bounds) }
        for row in snapshot.rows {
            guard let name = row.siteName, let site = sites[name], site.definition.siteClass == .core else {
                throw PhysicalDesignTechnologyError.invalid("Row \(row.id) requires a declared CORE site.")
            }
            let rotated = Self.swapsAxes(row.orientation)
            guard row.siteWidth == (rotated ? site.height : site.width),
                  row.height == (rotated ? site.width : site.height) else {
                throw PhysicalDesignTechnologyError.invalid("Row \(row.id) dimensions contradict the oriented site SIZE.")
            }
            try Self.validateBounds(.init(x: row.originX, y: row.originY, width: row.siteWidth * row.siteCount, height: row.height))
        }
        for cell in snapshot.cells {
            let master = try requireMaster(cell.master)
            // FIXME(INCOMPLETE_IMPLEMENTATION): Native API/CLI row placement currently admits CORE masters only. Other macro classes require profile-specific placement, site and obstruction contracts before successful mutation.
            guard master.definition.macroClass == .core else {
                throw PhysicalDesignTechnologyError.unsupported("Master \(cell.master) requires a supported native CORE placement profile.")
            }
            try Self.validateBounds(.init(x: cell.x, y: cell.y, width: cell.width, height: cell.height))
            let rotated = Self.swapsAxes(cell.orientation)
            guard cell.width == (rotated ? master.height : master.width), cell.height == (rotated ? master.width : master.height),
                  Self.allows(cell.orientation, symmetry: master.definition.symmetry) else {
                throw PhysicalDesignTechnologyError.invalid("Cell \(cell.id) dimensions or orientation contradict its exact master.")
            }
            // Project OBS as well as pin shapes, so overflow cannot hide in an unused port.
            _ = try obstructionShapes(master: cell.master, orientation: cell.orientation, x: cell.x, y: cell.y)
            instancePins[cell.id] = try master.pins.mapValues { pin in
                try pinShapes(master: cell.master, pin: pin.definition.name, orientation: cell.orientation, x: cell.x, y: cell.y)
            }
            if cell.placed, requirePlacementRows || !snapshot.rows.isEmpty {
                let bounds = PhysicalDesignSnapshot.Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)
                guard let core = snapshot.core, core.contains(bounds), rowsByY[cell.y, default: []].contains(where: { row in
                    guard row.siteName == master.definition.site, cell.y == row.originY,
                          cell.height == row.height, cell.x >= row.originX,
                          cell.width.isMultiple(of: row.siteWidth),
                          (cell.x - row.originX).isMultiple(of: row.siteWidth) else { return false }
                    let rowBounds = PhysicalDesignSnapshot.Rect(x: row.originX, y: row.originY,
                        width: row.siteWidth * row.siteCount, height: row.height)
                    return rowBounds.contains(bounds) && canPlace(cell, on: row)
                }) else {
                    throw PhysicalDesignTechnologyError.invalid("Placed cell \(cell.id) requires compatible source site geometry and row lattice.")
                }
            }
        }
        for pin in snapshot.pins {
            guard let layer = pin.accessLayer, let number = Int16(exactly: layer), layers[number]?.isRoutingLayer == true else {
                throw PhysicalDesignTechnologyError.invalid("Pin \(pin.id) requires an explicit mapped routing access layer.")
            }
            guard let cellID = pin.cellID else { continue }
            guard let cell = cells[cellID], let sourcePin = masters[cell.master]?.pins[pin.name],
                  let direction = sourcePin.definition.direction,
                  pin.direction.uppercased() == direction.rawValue else {
                throw PhysicalDesignTechnologyError.invalid("Pin \(pin.id) requires an exact master pin and declared direction.")
            }
            let shapes = (instancePins[cell.id]?[pin.name] ?? []).filter { $0.layer == number }
            let point = try Self.point(x: pin.x, y: pin.y)
            guard !shapes.isEmpty, Region(layer: number, polygons: shapes).contains(point) else {
                throw PhysicalDesignTechnologyError.invalid("Pin \(pin.id) access point is outside its exact source port on the selected layer.")
            }
        }
        for via in snapshot.vias {
            guard let name = via.master, let source = vias[name],
                  via.lowerLayer == Int(source.lowerLayer), via.upperLayer == Int(source.upperLayer), let die = snapshot.die else {
                throw PhysicalDesignTechnologyError.invalid("Via \(via.id) requires an exact fixed master and matching routing layers.")
            }
            for shape in try viaShapes(master: name, x: via.x, y: via.y) {
                guard shape.points.allSatisfy({ die.containsPoint(x: Int64($0.x), y: Int64($0.y)) }) else {
                    throw PhysicalDesignTechnologyError.invalid("Via \(via.id) source footprint is outside the die.")
                }
            }
        }
    }

    func canPlace(_ cell: PhysicalDesignSnapshot.Cell, on row: PhysicalDesignSnapshot.Row) -> Bool {
        guard let master = masters[cell.master], let name = row.siteName, name == master.definition.site,
              let site = sites[name], cell.height == row.height, cell.width.isMultiple(of: row.siteWidth) else { return false }
        return Self.allows(cell.orientation, symmetry: master.definition.symmetry)
            && Self.allowsRelative(cell.orientation, to: row.orientation, symmetry: site.definition.symmetry)
    }

    private static func swapsAxes(_ orientation: DEFOrientation) -> Bool {
        [.e, .w, .fe, .fw].contains(orientation)
    }

    private static func allows(_ orientation: DEFOrientation, symmetry: [LEFMacroDef.Symmetry]) -> Bool {
        if symmetry.contains(.r90) {
            return symmetry.contains(.x) || symmetry.contains(.y) || [.n, .s, .e, .w].contains(orientation)
        }
        switch orientation {
        case .n: return true
        case .fs: return symmetry.contains(.x)
        case .fn: return symmetry.contains(.y)
        case .s: return symmetry.contains(.x) && symmetry.contains(.y)
        default: return false
        }
    }

    private static func allowsRelative(_ cell: DEFOrientation, to row: DEFOrientation, symmetry: [LEFMacroDef.Symmetry]) -> Bool {
        func basis(_ orientation: DEFOrientation) -> (Int, Int, Int, Int) {
            let transform = DEFIRConverter.orientationToTransform(orientation)
            let sign = transform.mirrorX ? -1 : 1
            switch transform.angle {
            case 90: return (0, 1, -sign, 0)
            case 180: return (-1, 0, 0, -sign)
            case 270: return (0, -1, sign, 0)
            default: return (1, 0, 0, sign)
            }
        }
        let (rx, ry, sx, sy) = basis(row)
        let (cx, cy, dx, dy) = basis(cell)
        let relative = (rx * cx + ry * cy, sx * cx + sy * cy, rx * dx + ry * dy, sx * dx + sy * dy)
        return DEFOrientation.allCases.contains { orientation in
            let candidate = basis(orientation)
            return candidate == relative && allows(orientation, symmetry: symmetry)
        }
    }

    private static func point(x: Int64, y: Int64) throws -> IRPoint {
        guard let x = Int32(exactly: x), let y = Int32(exactly: y) else {
            throw PhysicalDesignTechnologyError.invalid("Native access coordinates exceed the exact geometry backend range.")
        }
        return .init(x: x, y: y)
    }

    private static func validateBounds(_ bounds: PhysicalDesignSnapshot.Rect) throws {
        let (maxX, overflowX) = bounds.x.addingReportingOverflow(bounds.width)
        let (maxY, overflowY) = bounds.y.addingReportingOverflow(bounds.height)
        guard !overflowX, !overflowY else { throw PhysicalDesignTechnologyError.invalid("Native geometry bounds overflow.") }
        _ = try point(x: bounds.x, y: bounds.y)
        _ = try point(x: maxX, y: maxY)
    }
}
