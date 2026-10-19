import MaskGeometry

/// Enclosed complement components of the complete layer union, in exact DBU squared.
enum PhysicalDesignHoleAreaGeometry {
    typealias Rectangle = PhysicalDesignRoutingSpacingObject.Rectangle

    static func areas(in region: borrowing Region, budget: inout PhysicalDesignRoutingWorkBudget, additionalCancellationCheck: () -> Bool = { false }) throws -> [UInt64] {
        try budget.charge(0)
        if region.isEmpty { return [] }
        let object: PhysicalDesignRoutingSpacingObject
        do { object = try PhysicalDesignRoutingSpacingObject.compile(region, budget: &budget, retainingMaterialBands: true, additionalCancellationCheck: additionalCancellationCheck) }
        catch RectilinearDecompositionError.cancelled { throw CancellationError() }
        guard let bands = object.materialBands, let first = bands.first else { return [] }
        var x0 = first.minX, x1 = first.maxX, y0 = first.minY, y1 = first.maxY
        var ordinates: Set<Int64> = []
        // The complement has at most (2*n-1)*(n+1) bands. Admit before allocation.
        let n = bands.count
        let square = n.multipliedReportingOverflow(by: n)
        let ceiling = square.partialValue.multipliedReportingOverflow(by: 16)
        guard !square.overflow, !ceiling.overflow else { throw invalid("Hole work ceiling exceeds the index range.") }
        try budget.extend(ceiling.partialValue)
        for band in bands {
            try budget.charge(3)
            x0 = min(x0, band.minX); x1 = max(x1, band.maxX)
            y0 = min(y0, band.minY); y1 = max(y1, band.maxY)
            ordinates.insert(band.minY); ordinates.insert(band.maxY)
        }
        try budget.admitSort(ordinates.count)
        let ys = ordinates.sorted()
        var empty: [Rectangle] = []
        for index in 0..<(ys.count - 1) {
            var intervals: [Rectangle] = []
            for band in bands {
                try budget.admit()
                if band.minY <= ys[index], band.maxY >= ys[index + 1] {
                    try budget.admit(); intervals.append(band)
                }
            }
            try budget.admitSort(intervals.count)
            intervals.sort { ($0.minX, $0.maxX) < ($1.minX, $1.maxX) }
            var cursor = x0
            for band in intervals {
                try budget.admit()
                if cursor < band.minX {
                    try budget.admit()
                    empty.append(.init(minX: cursor, minY: ys[index], maxX: band.minX, maxY: ys[index + 1]))
                }
                cursor = max(cursor, band.maxX)
            }
            if cursor < x1 {
                try budget.admit()
                empty.append(.init(minX: cursor, minY: ys[index], maxX: x1, maxY: ys[index + 1]))
            }
        }
        // Original bounds avoid Int32 +/-1 overflow at the edges of the geometry domain.
        let complement = PhysicalDesignRoutingSpacingObject(rectangles: [], materialBands: empty, edges: [])
        let components = try PhysicalDesignRoutingAreaGeometry.components(of: complement, budget: &budget)
        var result: [UInt64] = []
        for component in components {
            try budget.admit()
            let b = component.bounds
            if b.minX > x0, b.maxX < x1, b.minY > y0, b.maxY < y1 {
                try budget.admit(); result.append(component.areaDBU2)
            }
        }
        return result
    }

    private static func invalid(_ message: String) -> PhysicalDesignTechnologyError {
        .invalid("MINENCLOSEDAREA: " + message)
    }
}
