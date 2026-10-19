import LayoutIR
import MaskGeometry

/// Contained rectangles establish local width; real outward boundaries admit violations.
enum PhysicalDesignRoutingSpacingGeometry {
    typealias Object = PhysicalDesignRoutingSpacingObject
    static func compile(_ region: borrowing Region) throws -> Object {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        return try Object.compile(region, budget: &budget)
    }
    static func separated(_ region: borrowing Region, from obstacle: borrowing Object,
        rule: borrowing PhysicalDesignRoutingSpacingRule, minimum: Int64,
        candidateWidthOverride: Int64? = nil, obstacleWidthOverride: Int64? = nil) throws -> Bool {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let candidate = try Object.compile(region, budget: &budget)
        return try separated(candidate, from: obstacle, rule: rule, minimum: minimum,
            candidateWidthOverride: candidateWidthOverride, obstacleWidthOverride: obstacleWidthOverride, budget: &budget)
    }
    static func separated(_ candidate: borrowing Object, from obstacle: borrowing Object,
        rule: borrowing PhysicalDesignRoutingSpacingRule, minimum: Int64,
        candidateWidthOverride: Int64? = nil, obstacleWidthOverride: Int64? = nil, budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        guard minimum >= 0 else {
            throw PhysicalDesignRoutingSourceError(code: "routing_spacing_invalid", message: "Caller spacing must be nonnegative.")
        }
        if let width = candidateWidthOverride, width <= 0 {
            throw PhysicalDesignRoutingSourceError(code: "routing_spacing_invalid", message: "Candidate width override must be positive.")
        }
        if let width = obstacleWidthOverride, width <= 0 {
            throw PhysicalDesignRoutingSourceError(code: "routing_spacing_invalid", message: "Obstacle width override must be positive.")
        }
        let (pairs, pairOverflow) = candidate.rectangles.count.multipliedReportingOverflow(by: obstacle.rectangles.count)
        let (edgeCount, edgeOverflow) = candidate.edges.count.addingReportingOverflow(obstacle.edges.count)
        guard !pairOverflow, !edgeOverflow, edgeCount < Int.max else { throw capacity() }
        let (work, overflow) = pairs.multipliedReportingOverflow(by: edgeCount + 1)
        guard !overflow else { throw capacity() }
        try budget.extend(work)
        for leftIndex in candidate.rectangles.indices {
            let left = candidate.rectangles[leftIndex]
            for rightIndex in obstacle.rectangles.indices {
                try budget.admit(); let right = obstacle.rectangles[rightIndex]
                let overlapX = min(left.maxX, right.maxX) - max(left.minX, right.minX)
                let overlapY = min(left.maxY, right.maxY) - max(left.minY, right.minY)
                let dx = max(0, -overlapX), dy = max(0, -overlapY)
                if dx == 0 && dy == 0 { return false }
                let prl = max(overlapX, overlapY)
                let required = max(minimum, try rule.spacing(maximumWidth: max(candidateWidthOverride ?? left.width, obstacleWidthOverride ?? right.width), parallelLength: prl))
                guard Int32(exactly: required) != nil else { throw capacity() }
                // Each squared operand is below nonnegative Int32 spacing on this branch.
                if dx < required && dy < required && dx * dx + dy * dy < required * required {
                    let x0 = max(left.minX, right.minX), x1 = min(left.maxX, right.maxX)
                    let y0 = max(left.minY, right.minY), y1 = min(left.maxY, right.maxY)
                    if try facingEdges(candidate, obstacle, minX: min(x0, x1), maxX: max(x0, x1),
                        minY: min(y0, y1), maxY: max(y0, y1), prl: prl,
                        horizontal: dx == 0, vertical: dy == 0, budget: &budget) { return false }
                }
            }
        }
        return true
    }
    private static func facingEdges(_ lhs: borrowing Object, _ rhs: borrowing Object,
        minX: Int64, maxX: Int64, minY: Int64, maxY: Int64, prl: Int64,
        horizontal: Bool, vertical: Bool, budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        var left = false, right = false, bottom = false, top = false
        func visit(_ edges: borrowing [Object.Edge]) throws {
            for index in edges.indices {
                try budget.admit(); let edge = edges[index]
                switch edge.side {
                case .top, .bottom:
                    let overlap = prl > 0 ? edge.upper > minX && edge.lower < maxX : edge.upper >= minX && edge.lower <= maxX
                    if overlap && edge.side == .top && (prl > 0 ? edge.position >= minY && edge.position < maxY : edge.position == minY) { bottom = true }
                    if overlap && edge.side == .bottom && (prl > 0 ? edge.position > minY && edge.position <= maxY : edge.position == maxY) { top = true }
                case .right, .left:
                    let overlap = prl > 0 ? edge.upper > minY && edge.lower < maxY : edge.upper >= minY && edge.lower <= maxY
                    if overlap && edge.side == .right && (prl > 0 ? edge.position >= minX && edge.position < maxX : edge.position == minX) { left = true }
                    if overlap && edge.side == .left && (prl > 0 ? edge.position > minX && edge.position <= maxX : edge.position == maxX) { right = true }
                }
            }
        }
        try visit(lhs.edges); try visit(rhs.edges)
        return ((horizontal || prl <= 0) && bottom && top) || ((vertical || prl <= 0) && left && right)
    }
    private static func capacity() -> PhysicalDesignSourceRouter.Failure {
        .init(code: "routing_coordinate_overflow", message: "Spacing geometry exceeds the integer backend.")
    }
}
