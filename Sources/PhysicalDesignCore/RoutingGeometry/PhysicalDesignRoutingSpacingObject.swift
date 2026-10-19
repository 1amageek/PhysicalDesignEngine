import Foundation
import LayoutIR
import MaskGeometry

/// Exact union facts; construction rows are local and retained arrays are immutable.
struct PhysicalDesignRoutingSpacingObject: Sendable {
    struct Rectangle: Sendable, Hashable {
        let minX: Int64, minY: Int64, maxX: Int64, maxY: Int64
        var width: Int64 { min(maxX - minX, maxY - minY) }
    }
    enum Side: Int, Sendable { case left, right, bottom, top }
    struct Edge: Sendable {
        let side: Side
        let position: Int64, lower: Int64
        var upper: Int64
    }
    private struct Interval: Equatable { let lower: Int64, upper: Int64 }
    private struct Row { let lower: Int64, upper: Int64; let intervals: [Interval] }
    let rectangles: [Rectangle]
    let materialBands: [Rectangle]?
    let edges: [Edge]

    static func compile(_ region: borrowing Region, budget: inout PhysicalDesignRoutingWorkBudget, retainingMaterialBands: Bool = false, additionalCancellationCheck: () -> Bool = { false }) throws -> Self {
        var count = 0
        for polygon in region.polygons {
            try Task.checkCancellation()
            count = try add(count, add(polygon.points.count, 1))
        }
        // Admit each phase from its actual input tables, rather than a raw-input fourth power.
        try budget.extend(add(count, 6))
        try budget.charge(count)
        if region.polygons.count == 1 {
            let points = region.polygons[0].points
            if let box = PolygonGeometry.boundingBox(of: points), box.minX < box.maxX, box.minY < box.maxY,
               PolygonGeometry.isManhattan(points),
               points.allSatisfy({ $0.x == box.minX || $0.x == box.maxX || $0.y == box.minY || $0.y == box.maxY }),
               points.contains(.init(x: box.minX, y: box.minY)), points.contains(.init(x: box.maxX, y: box.minY)),
               points.contains(.init(x: box.maxX, y: box.maxY)), points.contains(.init(x: box.minX, y: box.maxY)) {
                try budget.charge(retainingMaterialBands ? 6 : 5)
                let x0 = Int64(box.minX), x1 = Int64(box.maxX), y0 = Int64(box.minY), y1 = Int64(box.maxY)
                return .init(rectangles: [.init(minX: x0, minY: y0, maxX: x1, maxY: y1)], materialBands: retainingMaterialBands ? [.init(minX: x0, minY: y0, maxX: x1, maxY: y1)] : nil, edges: [
                    .init(side: .left, position: x0, lower: y0, upper: y1), .init(side: .right, position: x1, lower: y0, upper: y1),
                    .init(side: .bottom, position: y0, lower: x0, upper: x1), .init(side: .top, position: y1, lower: x0, upper: x1)])
            }
        }
        var probes = 0
        for polygon in region.polygons {
            guard let bounds = PolygonGeometry.boundingBox(of: polygon.points), bounds.minX < bounds.maxX,
                  bounds.minY < bounds.maxY, PolygonGeometry.isManhattan(polygon.points) else {
                throw PhysicalDesignRoutingSourceError(code: "routing_spacing_geometry_invalid", message: "Spacing requires positive-area orthogonal metal.")
            }
            var ys: Set<Int32> = []
            for point in polygon.points { ys.insert(point.y) }
            probes = try add(probes, multiply(polygon.points.count, add(ys.count, 1)))
        }
        // Pre-admit the lower scanline traversal and the maximum number of emitted bands.
        try budget.extend(probes); try budget.charge(probes)
        let bands = try region.rectilinearBands(limits: .init(maximumInputEntries: count,
            maximumEdgeProbes: probes, maximumOutputBands: probes), isCancelled: { Task.isCancelled || additionalCancellationCheck() })
        guard !bands.isEmpty else {
            throw PhysicalDesignRoutingSourceError(code: "routing_spacing_geometry_invalid", message: "Spacing requires nonempty metal coverage.")
        }
        let boundaryEntries = try multiply(bands.count, 2)
        try budget.extend(add(boundaryEntries, sortWork(boundaryEntries)))
        var ys: Set<Int64> = []
        for band in bands { try budget.charge(2); ys.insert(Int64(band.minY)); ys.insert(Int64(band.maxY)) }
        try budget.charge(sortWork(ys.count))
        let levels = ys.sorted()
        let rowCount = levels.count - 1
        let rowWork = try add(add(multiply(4, bands.count), sortWork(bands.count)), 1)
        try budget.extend(multiply(rowCount, rowWork))
        var rows: [Row] = []
        for index in 0..<(levels.count - 1) {
            var intervals: [Interval] = []
            for band in bands {
                try budget.admit()
                if Int64(band.minY) <= levels[index], Int64(band.maxY) >= levels[index + 1] {
                    try budget.admit(); intervals.append(.init(lower: Int64(band.minX), upper: Int64(band.maxX)))
                }
            }
            intervals = try union(intervals, budget: &budget)
            try budget.admit(); rows.append(.init(lower: levels[index], upper: levels[index + 1], intervals: intervals))
        }
        try budget.extend(rows.count)
        var intervalCount = 0, maximumIntervals = 0, edgeWork = 0
        for index in rows.indices {
            try budget.admit()
            let current = rows[index].intervals.count
            intervalCount = try add(intervalCount, current)
            maximumIntervals = max(maximumIntervals, current)
            let previous = index > 0 ? rows[index - 1].intervals.count : 0
            let next = index + 1 < rows.count ? rows[index + 1].intervals.count : 0
            // Per difference: C*P scan charges plus at most 2*C*(P+1) emitted-edge charges.
            edgeWork = try add(edgeWork, multiply(current, add(multiply(3, add(previous, next)), 6)))
        }
        try budget.extend(edgeWork)
        var edges: [Edge] = []
        for index in rows.indices {
            let row = rows[index]
            for interval in row.intervals {
                try budget.charge(2)
                edges.append(.init(side: .left, position: interval.lower, lower: row.lower, upper: row.upper))
                edges.append(.init(side: .right, position: interval.upper, lower: row.lower, upper: row.upper))
            }
            let previous = index > 0 ? rows[index - 1].intervals : []
            let next = index + 1 < rows.count ? rows[index + 1].intervals : []
            for interval in try difference(row.intervals, previous, budget: &budget) {
                try budget.admit(); edges.append(.init(side: .bottom, position: row.lower, lower: interval.lower, upper: interval.upper))
            }
            for interval in try difference(row.intervals, next, budget: &budget) {
                try budget.admit(); edges.append(.init(side: .top, position: row.upper, lower: interval.lower, upper: interval.upper))
            }
        }
        try budget.extend(add(sortWork(edges.count), multiply(2, edges.count)))
        try budget.charge(sortWork(edges.count))
        edges.sort { ($0.side.rawValue, $0.position, $0.lower, $0.upper) < ($1.side.rawValue, $1.position, $1.lower, $1.upper) }
        var perimeter: [Edge] = []
        for edge in edges {
            try budget.admit()
            if let last = perimeter.last, last.side == edge.side, last.position == edge.position, last.upper == edge.lower {
                perimeter[perimeter.count - 1].upper = edge.upper
            } else { try budget.admit(); perimeter.append(edge) }
        }
        // Every common interval endpoint comes from an admitted row, so at most I remain.
        // Each row pair intersects at most I+M intervals, covers two adjacent rows, and emits at most I rectangles.
        let pairs = try multiply(rowCount, add(rowCount, 1)) / 2
        let intersectionWork = try multiply(2, add(intervalCount, maximumIntervals))
        let coverageAndOutput = try multiply(intervalCount, add(multiply(2, maximumIntervals), 1))
        let pairWork = try add(1, add(intersectionWork, coverageAndOutput))
        try budget.extend(add(rowCount, multiply(pairs, pairWork)))
        var rectangles: [Rectangle] = []
        for start in rows.indices {
            try budget.admit()
            var common = rows[start].intervals
            for end in start..<rows.count {
                try budget.admit()
                if end > start { common = try intersection(common, rows[end].intervals, budget: &budget) }
                if common.isEmpty { break }
                for interval in common {
                    let down = start > 0 ? try covers(rows[start - 1].intervals, interval, budget: &budget) : false
                    let up = end + 1 < rows.count ? try covers(rows[end + 1].intervals, interval, budget: &budget) : false
                    if !down && !up {
                        try budget.admit(); rectangles.append(.init(minX: interval.lower, minY: rows[start].lower,
                            maxX: interval.upper, maxY: rows[end].upper))
                    }
                }
            }
        }
        var material: [Rectangle] = []
        if retainingMaterialBands {
            try budget.extend(intervalCount)
            for row in rows {
                for interval in row.intervals {
                    try budget.admit()
                    material.append(.init(minX: interval.lower, minY: row.lower, maxX: interval.upper, maxY: row.upper))
                }
            }
        }
        return .init(rectangles: rectangles, materialBands: retainingMaterialBands ? material : nil, edges: perimeter)
    }
    private static func union(_ input: consuming [Interval], budget: inout PhysicalDesignRoutingWorkBudget) throws -> [Interval] {
        var sorted = input
        try budget.charge(sortWork(sorted.count))
        sorted.sort { ($0.lower, $0.upper) < ($1.lower, $1.upper) }
        var result: [Interval] = []
        for interval in sorted {
            try budget.admit()
            if let last = result.last, interval.lower <= last.upper {
                result[result.count - 1] = .init(lower: last.lower, upper: max(last.upper, interval.upper))
            } else { try budget.admit(); result.append(interval) }
        }
        return result
    }
    private static func intersection(_ lhs: borrowing [Interval], _ rhs: borrowing [Interval],
        budget: inout PhysicalDesignRoutingWorkBudget) throws -> [Interval] {
        var result: [Interval] = [], left = 0, right = 0
        while left < lhs.count && right < rhs.count {
            try budget.admit()
            let lower = max(lhs[left].lower, rhs[right].lower), upper = min(lhs[left].upper, rhs[right].upper)
            if lower < upper { try budget.admit(); result.append(.init(lower: lower, upper: upper)) }
            if lhs[left].upper <= rhs[right].upper { left += 1 } else { right += 1 }
        }
        return result
    }
    private static func difference(_ lhs: borrowing [Interval], _ rhs: borrowing [Interval],
        budget: inout PhysicalDesignRoutingWorkBudget) throws -> [Interval] {
        var result: [Interval] = []
        for index in lhs.indices {
            let interval = lhs[index]; var lower = interval.lower
            for otherIndex in rhs.indices {
                try budget.admit(); let other = rhs[otherIndex]
                if other.upper <= lower { continue }
                if other.lower >= interval.upper { break }
                if lower < other.lower { try budget.admit(); result.append(.init(lower: lower, upper: other.lower)) }
                lower = max(lower, other.upper)
                if lower >= interval.upper { break }
            }
            if lower < interval.upper { try budget.admit(); result.append(.init(lower: lower, upper: interval.upper)) }
        }
        return result
    }
    private static func covers(_ intervals: borrowing [Interval], _ target: Interval,
        budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        for index in intervals.indices {
            try budget.admit(); let interval = intervals[index]
            if interval.lower <= target.lower && interval.upper >= target.upper { return true }
        }
        return false
    }
    private static func sortWork(_ count: Int) throws -> Int {
        var levels = 0, size = count
        while size > 1 { levels += 1; size = size / 2 + size % 2 }
        return try multiply(2, multiply(count, max(1, levels)))
    }
    private static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw PhysicalDesignSourceRouter.Failure(code: "routing_coordinate_overflow", message: "Geometry work exceeds the index range.") }; return value
    }
    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw PhysicalDesignSourceRouter.Failure(code: "routing_coordinate_overflow", message: "Geometry input exceeds the index range.") }; return value
    }
}
