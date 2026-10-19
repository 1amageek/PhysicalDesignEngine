import MaskGeometry

/// Exact metal area from disjoint union bands, with positive-edge connectivity.
enum PhysicalDesignRoutingAreaGeometry {
    typealias Rectangle = PhysicalDesignRoutingSpacingObject.Rectangle
    struct Component: Sendable {
        let areaDBU2: UInt64
        let bands: [Rectangle]
        let bounds: Rectangle
    }

    static func compile(_ region: borrowing Region, budget: inout PhysicalDesignRoutingWorkBudget) throws -> [Component] {
        try budget.charge(0)
        if region.isEmpty { return [] }
        let object = try PhysicalDesignRoutingSpacingObject.compile(region, budget: &budget, retainingMaterialBands: true)
        return try components(of: object, budget: &budget)
    }

    static func components(of object: borrowing PhysicalDesignRoutingSpacingObject,
        budget: inout PhysicalDesignRoutingWorkBudget) throws -> [Component] {
        guard let bands = object.materialBands else { throw invalid("Area evaluation requires retained union material facts.") }
        let count = bands.count
        try budget.charge(0)
        if count == 0 { return [] }
        var levels = 1, size = count
        while size > 1 { levels += 1; size = size / 2 + size % 2 }
        let pairs = try multiply(count, count)
        let pairWork = try multiply(pairs, 2 * levels + 3)
        let outputWork = try multiply(try multiply(count, 8), levels + 1)
        try budget.extend(try add(pairWork, outputWork))
        try budget.charge(try multiply(count, 3))
        var parent = Array(0..<count)
        var rank = Array(repeating: 0, count: count)
        var groupIndex = Array(repeating: -1, count: count)
        for band in bands {
            try budget.admit()
            guard [band.minX, band.minY, band.maxX, band.maxY].allSatisfy({ Int32(exactly: $0) != nil }),
                  band.maxX > band.minX, band.maxY > band.minY else { throw invalid("Union material bands exceed the positive Int32 geometry domain.") }
        }
        for index in bands.indices {
            let a = bands[index]
            for other in (index + 1)..<count {
                try budget.admit()
                let b = bands[other]
                let x = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let y = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                guard (x > 0 && y >= 0) || (x >= 0 && y > 0) else { continue }
                let first = try root(index, parent: &parent, budget: &budget)
                let second = try root(other, parent: &parent, budget: &budget)
                if first != second {
                    if rank[first] < rank[second] { parent[first] = second }
                    else {
                        parent[second] = first
                        if rank[first] == rank[second] { rank[first] += 1 }
                    }
                }
            }
        }
        var members: [[Rectangle]] = [], areas: [UInt64] = [], bounds: [Rectangle] = []
        for index in bands.indices {
            let owner = try root(index, parent: &parent, budget: &budget)
            let band = bands[index]
            if groupIndex[owner] < 0 {
                try budget.charge(3)
                groupIndex[owner] = members.count
                members.append([]); areas.append(0); bounds.append(band)
            }
            let group = groupIndex[owner]
            let product = UInt64(band.maxX - band.minX).multipliedReportingOverflow(by: UInt64(band.maxY - band.minY))
            let total = areas[group].addingReportingOverflow(product.partialValue)
            guard !product.overflow, !total.overflow else { throw invalid("Union component area exceeds UInt64 DBU-squared range.") }
            try budget.admit()
            members[group].append(band)
            areas[group] = total.partialValue
            let previous = bounds[group]
            bounds[group] = .init(minX: min(previous.minX, band.minX), minY: min(previous.minY, band.minY),
                maxX: max(previous.maxX, band.maxX), maxY: max(previous.maxY, band.maxY))
        }
        var result: [Component] = []
        for index in members.indices {
            try budget.admit()
            result.append(.init(areaDBU2: areas[index], bands: members[index], bounds: bounds[index]))
        }
        return result
    }

    private static func root(_ index: Int, parent: inout [Int], budget: inout PhysicalDesignRoutingWorkBudget) throws -> Int {
        var node = index
        try budget.admit()
        while parent[node] != node {
            try budget.admit()
            parent[node] = parent[parent[node]]
            node = parent[node]
        }
        return node
    }
    private static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw invalid("Area work ceiling exceeds the index range.") }
        return result.partialValue
    }
    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw invalid("Area work ceiling exceeds the index range.") }
        return result.partialValue
    }
    private static func invalid(_ message: String) -> PhysicalDesignRoutingSourceError {
        .init(code: "routing_area_geometry_invalid", message: message)
    }
}
