import LayoutIR

struct PhysicalDesignManufacturingGrid: Sendable {
    let stepDBU: Int64?

    init(inputs: PhysicalDesignProcessInputs?, units: Int) throws {
        var step: Int64?
        if let inputs {
            for document in Array(inputs.technologyViews.values) + Array(inputs.cellViews.values) {
                guard let value = document.manufacturingGrid else { continue }
                let projected = try PhysicalDesignProcessInputs.dbu(value, units: units, field: "MANUFACTURINGGRID", positive: true)
                guard step == nil || step == projected else {
                    throw PhysicalDesignTechnologyError.invalid("Selected MANUFACTURINGGRID declarations disagree.")
                }
                step = projected
            }
        }
        stepDBU = step
    }

    func validate(_ value: Int64, field: String) throws {
        guard let stepDBU else { return }
        guard value.isMultiple(of: stepDBU) else {
            throw PhysicalDesignTechnologyError.invalid("MANUFACTURINGGRID violation in \(field): \(value) DBU is not a multiple of \(stepDBU).")
        }
    }

    func validate(_ shape: IRBoundary, field: String) throws {
        guard stepDBU != nil else { return }
        try Task.checkCancellation()
        for point in shape.points {
            try validate(Int64(point.x), field: field)
            try validate(Int64(point.y), field: field)
        }
    }

    func validate(_ rectangle: PhysicalDesignSnapshot.Rect, field: String) throws {
        guard stepDBU != nil else { return }
        let x = rectangle.x.addingReportingOverflow(rectangle.width)
        let y = rectangle.y.addingReportingOverflow(rectangle.height)
        guard !x.overflow, !y.overflow else { throw PhysicalDesignTechnologyError.invalid("MANUFACTURINGGRID bounds overflow in \(field).") }
        for value in [rectangle.x, rectangle.y, x.partialValue, y.partialValue] { try validate(value, field: field) }
    }

    func validate(_ snapshot: PhysicalDesignSnapshot) throws {
        guard stepDBU != nil else { return }
        try Task.checkCancellation()
        if let die = snapshot.die { try validate(die, field: "die") }
        if let core = snapshot.core { try validate(core, field: "core") }
        for row in snapshot.rows {
            try validate(row.originX, field: "row \(row.id)")
            try validate(row.originY, field: "row \(row.id)")
            try validate(row.siteWidth, field: "row \(row.id)")
            try validate(row.height, field: "row \(row.id)")
        }
        for cell in snapshot.cells {
            try validate(.init(x: cell.x, y: cell.y, width: cell.width, height: cell.height), field: "cell \(cell.id)")
        }
        for pin in snapshot.pins {
            if let port = pin.topPort {
                do { try validate(port.worldRectangle(), field: "top port \(pin.id)") }
                catch let error as PhysicalDesignTechnologyError { throw error }
                catch { throw PhysicalDesignTechnologyError.invalid("MANUFACTURINGGRID requires valid top-port geometry: \(error)") }
            }
        }
        for route in snapshot.routes {
            for segment in route.segments {
                do { try validate(segment.qualifiedFootprint(), field: "route \(route.id)/\(segment.id)") }
                catch let error as PhysicalDesignTechnologyError { throw error }
                catch { throw PhysicalDesignTechnologyError.invalid("MANUFACTURINGGRID requires qualified route geometry: \(error)") }
            }
        }
        for structure in snapshot.powerStructures { try validate(structure.geometry, field: "power \(structure.id)") }
        for fill in snapshot.fills { try validate(fill.geometry, field: "fill \(fill.id)") }
    }
}
