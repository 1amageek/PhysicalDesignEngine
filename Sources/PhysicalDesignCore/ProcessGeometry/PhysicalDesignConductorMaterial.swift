import LayoutIR
import MaskGeometry

/// Known layer material and the provenance needed for candidate AREA admission.
struct PhysicalDesignConductorMaterial {
    var all: [IRBoundary] = []
    var constructed: [IRBoundary] = []
    var abstractPorts: [IRBoundary] = []
}

extension PhysicalDesignProcessGeometry {
    func conductorMaterial(_ snapshot: PhysicalDesignSnapshot, layers: Set<Int16>,
        trackingAreaProvenance: Bool = false, budget: inout PhysicalDesignRoutingWorkBudget
    ) throws -> [Int16: PhysicalDesignConductorMaterial] {
        var material: [Int16: PhysicalDesignConductorMaterial] = [:]
        for cell in snapshot.cells {
            try budget.extend(1); try budget.admit()
            let master = try requireMaster(cell.master)
            try budget.admitSort(master.pins.count)
            for name in master.pins.keys.sorted() {
                guard let pin = master.pins[name] else { throw PhysicalDesignTechnologyError.invalid("Source PORT disappeared during conductor admission.") }
                try Self.admitConductorProjection(pin.shapes, budget: &budget)
                let shapes = try pinShapes(master: cell.master, pin: name, orientation: cell.orientation, x: cell.x, y: cell.y)
                appendConductorMaterial(shapes, layers: layers, constructed: false, abstractPort: trackingAreaProvenance, to: &material)
            }
        }
        for pin in snapshot.pins where pin.cellID == nil {
            try budget.extend(8); try budget.charge(8)
            guard let port = pin.topPort else { throw PhysicalDesignTechnologyError.invalid("Source conductor admission requires exact top PORT material.") }
            appendConductorMaterial(try PhysicalDesignSourceRouter.rectangle(port.worldRectangle(), layer: port.layer).polygons, layers: layers, constructed: false, abstractPort: false, to: &material)
        }
        for route in snapshot.routes {
            for segment in route.segments {
                try budget.extend(8); try budget.charge(8)
                let footprint: PhysicalDesignSnapshot.Rect
                do { footprint = try segment.qualifiedFootprint() }
                catch { throw PhysicalDesignTechnologyError.invalid("Source conductor admission requires qualified full route material: \(error)") }
                appendConductorMaterial(try PhysicalDesignSourceRouter.rectangle(footprint, layer: segment.layer).polygons, layers: layers, constructed: trackingAreaProvenance, abstractPort: false, to: &material)
            }
        }
        for via in snapshot.vias {
            guard let name = via.master, let source = vias[name] else { throw PhysicalDesignTechnologyError.invalid("Source conductor admission requires an exact fixed VIA master.") }
            try Self.admitConductorProjection(source.shapes, budget: &budget)
            appendConductorMaterial(try viaShapes(master: name, x: via.x, y: via.y), layers: layers, constructed: trackingAreaProvenance, abstractPort: false, to: &material)
        }
        for structure in snapshot.powerStructures {
            try budget.extend(8); try budget.charge(8)
            appendConductorMaterial(try PhysicalDesignSourceRouter.rectangle(structure.geometry, layer: structure.layer).polygons, layers: layers, constructed: trackingAreaProvenance, abstractPort: false, to: &material)
        }
        for fill in snapshot.fills {
            try budget.extend(8); try budget.charge(8)
            appendConductorMaterial(try PhysicalDesignSourceRouter.rectangle(fill.geometry, layer: fill.layer).polygons, layers: layers, constructed: trackingAreaProvenance, abstractPort: false, to: &material)
        }
        return material
    }

    private func appendConductorMaterial(_ shapes: borrowing [IRBoundary], layers: Set<Int16>,
        constructed: Bool, abstractPort: Bool, to material: inout [Int16: PhysicalDesignConductorMaterial]) {
        for index in shapes.indices {
            let shape = shapes[index]
            guard layers.contains(shape.layer) else { continue }
            material[shape.layer, default: .init()].all.append(shape)
            if constructed { material[shape.layer, default: .init()].constructed.append(shape) }
            if abstractPort { material[shape.layer, default: .init()].abstractPorts.append(shape) }
        }
    }

    private static func admitConductorProjection(_ shapes: borrowing [IRBoundary], budget: inout PhysicalDesignRoutingWorkBudget) throws {
        for index in shapes.indices {
            let count = shapes[index].points.count.addingReportingOverflow(1)
            guard !count.overflow else { throw PhysicalDesignTechnologyError.invalid("Source conductor vertex count overflows.") }
            try budget.extend(count.partialValue); try budget.charge(count.partialValue)
        }
    }
}
