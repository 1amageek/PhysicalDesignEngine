import LEF

struct PhysicalDesignExportGeometryBudget {
    private var records: UInt64 = 0
    private let limit: UInt64

    private mutating func add(_ value: Int) throws {
        try Task.checkCancellation()
        let (next, overflow) = records.addingReportingOverflow(UInt64(value))
        guard !overflow, next <= limit else { throw PhysicalDesignStandardLayoutExportError.limitExceeded(.geometryRecords) }
        records = next
    }

    private mutating func multiply(_ factor: UInt64) throws {
        let (next, overflow) = records.multipliedReportingOverflow(by: factor)
        guard !overflow, next <= limit else { throw PhysicalDesignStandardLayoutExportError.limitExceeded(.geometryRecords) }
        records = next
    }

    private mutating func shapes(rects: [LEFRect], polygons: [[LEFPoint]]) throws {
        for _ in rects { try add(5) }
        for polygon in polygons { try add(polygon.count); try add(1) }
    }

    static func validate(inputs: PhysicalDesignProcessInputs, snapshot: PhysicalDesignSnapshot, limit: UInt64) throws {
        var budget = Self(limit: limit)
        var viaVertices = Self(limit: limit)
        try budget.add(inputs.manifest.assets.count)
        try budget.add(inputs.manifest.layers.count)
        for layer in inputs.manifest.layers { try budget.add(layer.aliases.count) }
        try budget.add(inputs.manifest.crossViewMappings.count)
        for mapping in inputs.manifest.crossViewMappings {
            try budget.add(mapping.layerIDs.count); try budget.add(mapping.physicalNames.count)
        }
        for document in inputs.technologyViews.values { for via in document.vias {
            for layer in via.layers { try viaVertices.shapes(rects: layer.rects, polygons: layer.polygons) }
        } }
        for document in inputs.cellViews.values { for via in document.vias {
            for layer in via.layers { try viaVertices.shapes(rects: layer.rects, polygons: layer.polygons) }
        } }
        for document in Array(inputs.technologyViews.values) + Array(inputs.cellViews.values) {
            try budget.add(document.layers.count); try budget.add(document.sites.count); try budget.add(document.macros.count)
            for via in document.vias { try budget.add(1); for layer in via.layers {
                try budget.shapes(rects: layer.rects, polygons: layer.polygons)
            } }
            func ports(_ ports: [LEFPort]) throws {
                for port in ports {
                    try budget.add(1); try budget.shapes(rects: port.rects, polygons: port.polygons)
                    for _ in port.vias {
                        // Conservatively allow every fixed stack for each PORT VIA before name resolution.
                        guard let count = Int(exactly: viaVertices.records) else { throw PhysicalDesignStandardLayoutExportError.limitExceeded(.geometryRecords) }
                        try budget.add(count)
                    }
                }
            }
            for master in document.macros {
                try budget.add(master.pins.count)
                try ports(master.obs)
                for pin in master.pins { try ports(pin.ports) }
            }
        }
        // Constructor projects the source once; admission projects every master per cell,
        // and retained contacts are projected by admission and by the native writer.
        let (viaFactor, viaOverflow) = UInt64(snapshot.vias.count).multipliedReportingOverflow(by: 2)
        let (instances, instanceOverflow) = UInt64(snapshot.cells.count).addingReportingOverflow(viaFactor)
        let (factor, factorOverflow) = instances.addingReportingOverflow(1)
        guard !viaOverflow, !instanceOverflow, !factorOverflow else { throw PhysicalDesignStandardLayoutExportError.limitExceeded(.geometryRecords) }
        try budget.multiply(factor)
        for count in [snapshot.rows.count, snapshot.cells.count, snapshot.pins.count, snapshot.nets.count,
                      snapshot.blockages.count, snapshot.powerStructures.count, snapshot.routes.count,
                      snapshot.vias.count, snapshot.fills.count, snapshot.clockTrees.count,
                      snapshot.implementationState?.tracks.count ?? 0,
                      snapshot.implementationState?.clockRouteConstraints.count ?? 0] { try budget.add(count) }
        for net in snapshot.nets { try budget.add(net.pinIDs.count) }
        for route in snapshot.routes { try budget.add(route.segments.count) }
    }
}
