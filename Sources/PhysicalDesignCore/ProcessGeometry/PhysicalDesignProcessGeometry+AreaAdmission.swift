import LayoutIR
import MaskGeometry

/// Candidate metal AREA from known union material, with explicit abstract-PORT uncertainty.
enum PhysicalDesignCTSAreaAdmission {
    static func validate(_ material: borrowing PhysicalDesignConductorMaterial, layer: Int16,
        threshold: UInt64, budget: inout PhysicalDesignRoutingWorkBudget,
        additionalCancellationCheck: () -> Bool = { false }
    ) throws {
        try budget.charge(0)
        guard !material.constructed.isEmpty else { return }
        let union = try compile(material.all, layer: layer, budget: &budget, additionalCancellationCheck: additionalCancellationCheck)
        let subjects = try compile(material.constructed, layer: layer, budget: &budget, additionalCancellationCheck: additionalCancellationCheck)
        let ports = try compile(material.abstractPorts, layer: layer, budget: &budget, additionalCancellationCheck: additionalCancellationCheck)
        guard let subjectBands = subjects.materialBands, let portBands = ports.materialBands else {
            throw PhysicalDesignTechnologyError.invalid("CTS AREA requires retained union provenance bands.")
        }
        let components = try PhysicalDesignRoutingAreaGeometry.components(of: union, budget: &budget)
        for component in components {
            try budget.admit()
            guard component.areaDBU2 < threshold else { continue }
            guard try touches(component.bands, subjectBands, budget: &budget) else { continue }
            if try touches(component.bands, portBands, budget: &budget) {
                throw PhysicalDesignTechnologyError.unsupported("CTS AREA on layer \(layer) is unproven: known component area \(component.areaDBU2) DBU squared is below \(threshold) and touches an abstract macro PORT.")
            }
            throw PhysicalDesignTechnologyError.invalid("CTS AREA on layer \(layer): complete known conductor island \(component.areaDBU2) DBU squared is below \(threshold).")
        }
    }

    private static func compile(_ shapes: borrowing [IRBoundary], layer: Int16,
        budget: inout PhysicalDesignRoutingWorkBudget, additionalCancellationCheck: () -> Bool
    ) throws -> PhysicalDesignRoutingSpacingObject {
        try budget.charge(0)
        if shapes.isEmpty { return .init(rectangles: [], materialBands: [], edges: []) }
        do {
            // Region owns a retained Array buffer for this synchronous compilation boundary.
            return try PhysicalDesignRoutingSpacingObject.compile(Region(layer: layer, polygons: copy shapes),
                budget: &budget, retainingMaterialBands: true, additionalCancellationCheck: additionalCancellationCheck)
        } catch RectilinearDecompositionError.cancelled {
            throw CancellationError()
        }
    }

    private static func touches(_ first: borrowing [PhysicalDesignRoutingSpacingObject.Rectangle],
        _ second: borrowing [PhysicalDesignRoutingSpacingObject.Rectangle],
        budget: inout PhysicalDesignRoutingWorkBudget
    ) throws -> Bool {
        for index in first.indices {
            try budget.extend(second.count)
            let a = first[index]
            for other in second.indices {
                try budget.admit()
                let b = second[other]
                let x = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let y = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                if (x > 0 && y >= 0) || (x >= 0 && y > 0) { return true }
            }
        }
        return false
    }
}

extension PhysicalDesignProcessGeometry {
    func validateCTSMetalAreas(_ snapshot: PhysicalDesignSnapshot) throws {
        var budget = PhysicalDesignRoutingWorkBudget(caller: maximumHoleGeometryChecks)
        let material = try conductorMaterial(snapshot, layers: Set(routingMinimumAreas.keys),
            trackingAreaProvenance: true, budget: &budget)
        try budget.admitSort(routingMinimumAreas.count)
        for layer in routingMinimumAreas.keys.sorted() {
            guard let threshold = routingMinimumAreas[layer] else {
                throw PhysicalDesignTechnologyError.invalid("CTS AREA source threshold disappeared.")
            }
            try PhysicalDesignCTSAreaAdmission.validate(material[layer] ?? .init(), layer: layer,
                threshold: threshold.minimumDBU2, budget: &budget)
        }
    }
}
