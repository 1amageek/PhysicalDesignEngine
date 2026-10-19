import LayoutIR
import MaskGeometry

/// Primitive cut identity is retained when checking overlap and positive edge spacing.
enum PhysicalDesignFixedCutSeparation {
    static func separated(_ first: IRBoundary, from second: IRBoundary, minimum: Int32) throws -> Bool {
        try Task.checkCancellation()
        let firstCount = first.points.count - (first.points.first == first.points.last ? 1 : 0)
        let secondCount = second.points.count - (second.points.first == second.points.last ? 1 : 0)
        guard firstCount >= 3, secondCount >= 3 else {
            throw PhysicalDesignTechnologyError.invalid("Fixed cut separation requires actual polygon vertices.")
        }
        let a = Region(layer: first.layer, polygons: [first])
        let b = Region(layer: second.layer, polygons: [second])
        guard try a.intersection(b).isEmpty else { return false }
        guard minimum > 0 else { return true }
        for i in 0..<firstCount {
            let edge = IREdge(p1: first.points[i], p2: first.points[(i + 1) % firstCount])
            for j in 0..<secondCount {
                try Task.checkCancellation()
                let other = IREdge(p1: second.points[j], p2: second.points[(j + 1) % secondCount])
                if PolygonGeometry.distance(between: edge, and: other) < Double(minimum) { return false }
            }
        }
        return true
    }
}
