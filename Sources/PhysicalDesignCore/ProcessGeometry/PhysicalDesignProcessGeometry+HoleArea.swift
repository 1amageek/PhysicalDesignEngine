import LayoutIR
import MaskGeometry

extension PhysicalDesignProcessGeometry {
    func validateHoleAreas(_ snapshot: PhysicalDesignSnapshot) throws {
        guard !minimumHoleAreas.isEmpty else { return }
        var budget = PhysicalDesignRoutingWorkBudget(caller: maximumHoleGeometryChecks)
        let material = try conductorMaterial(snapshot, layers: Set(minimumHoleAreas.keys), budget: &budget)
        try budget.admitSort(minimumHoleAreas.count)
        for layer in minimumHoleAreas.keys.sorted() {
            guard let threshold = minimumHoleAreas[layer] else { throw PhysicalDesignTechnologyError.invalid("MINENCLOSEDAREA threshold disappeared.") }
            let holes = try PhysicalDesignHoleAreaGeometry.areas(in: Region(layer: layer, polygons: material[layer]?.all ?? []), budget: &budget)
            for area in holes {
                try budget.admit()
                guard area >= threshold else {
                    throw PhysicalDesignTechnologyError.invalid("MINENCLOSEDAREA on \(sourceLayers[layer]?.name ?? String(layer)): enclosed hole \(area) DBU squared is below \(threshold).")
                }
            }
        }
    }

}
