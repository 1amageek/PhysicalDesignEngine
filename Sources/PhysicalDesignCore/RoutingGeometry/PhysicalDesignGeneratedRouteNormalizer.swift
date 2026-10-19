import Foundation

/// Normalizes unpublished generated paths without changing their physical metal or graph anchors.
enum PhysicalDesignGeneratedRouteNormalizer {
    struct Point: Sendable, Hashable {
        let x: Int64, y: Int64
        let layer: Int
    }
    private struct PhysicalEdge: Hashable {
        let first: Point, last: Point
        let width: Int64
        let isJumper: Bool

        init?(_ segment: PhysicalDesignSnapshot.RouteSegment) {
            guard let width = segment.widthDBU,
                  segment.endpointExtensions == .init(beginDBU: width / 2, endDBU: width / 2) else { return nil }
            let forward = (segment.x1, segment.y1) < (segment.x2, segment.y2)
            first = .init(x: forward ? segment.x1 : segment.x2, y: forward ? segment.y1 : segment.y2, layer: segment.layer)
            last = .init(x: forward ? segment.x2 : segment.x1, y: forward ? segment.y2 : segment.y1, layer: segment.layer)
            self.width = width; isJumper = segment.isJumper
        }
    }
    private struct Neighbors {
        var first: Point?
        var second: Point?
        var branched = false
        mutating func insert(_ point: Point) {
            if first == point || second == point || branched { return }
            if first == nil { first = point }
            else if second == nil { second = point }
            else { branched = true }
        }
    }

    static func normalize(_ input: borrowing [PhysicalDesignSnapshot.RouteSegment],
        paths: borrowing [Range<Int>], protectedPoints: borrowing Set<Point>,
        budget: inout PhysicalDesignRoutingWorkBudget) throws -> [PhysicalDesignSnapshot.RouteSegment] {
        let count = input.count
        let endpoints = try multiply(count, 2)
        // Input/output, unique IDs, exact physical edges and at most two endpoint entries per segment.
        let storage = try add(try multiply(count, 6), try add(paths.count, protectedPoints.count))
        try budget.extend(storage); try budget.charge(storage)
        try budget.extend(try add(try multiply(count, 3), paths.count))
        var neighbors: [Point: Neighbors] = [:]
        neighbors.reserveCapacity(endpoints)
        var covered = 0
        for pathIndex in paths.indices {
            let path = paths[pathIndex]
            try budget.admit()
            guard path.lowerBound == covered, path.upperBound <= count else { throw invalid("Generated path ranges must partition the wire inventory.") }
            covered = path.upperBound
        }
        guard covered == count else { throw invalid("Generated path ranges leave unowned wires.") }
        var ids: Set<String> = []
        ids.reserveCapacity(count)
        for index in input.indices {
            let segment = input[index]
            try budget.admit()
            _ = try segment.qualifiedFootprint()
            guard ids.insert(segment.id).inserted else { throw invalid("Generated wire identities must be unique.") }
            let first = Point(x: segment.x1, y: segment.y1, layer: segment.layer)
            let last = Point(x: segment.x2, y: segment.y2, layer: segment.layer)
            try budget.admit(); neighbors[first, default: Neighbors()].insert(last)
            try budget.admit(); neighbors[last, default: Neighbors()].insert(first)
        }
        // Output is bounded by the original inventory. Each path keeps its own run boundary.
        try budget.extend(try add(paths.count, endpoints))
        var result: [PhysicalDesignSnapshot.RouteSegment] = []
        result.reserveCapacity(count)
        for pathIndex in paths.indices {
            let path = paths[pathIndex]
            try budget.admit()
            let firstOutput = result.count
            for index in path {
                try budget.admit()
                let current = input[index]
                try budget.admit()
                if result.count > firstOutput,
                   let merged = merge(result[result.count - 1], current, protectedPoints: protectedPoints, neighbors: neighbors) {
                    result[result.count - 1] = merged
                } else { result.append(current) }
            }
        }
        // One invocation owns one unpublished net; identical shared trunks have one physical edge.
        try budget.extend(try multiply(count, 2))
        var seen: Set<PhysicalEdge> = []
        seen.reserveCapacity(count)
        var write = 0
        for read in result.indices {
            try budget.charge(2)
            let segment = result[read]
            if let key = PhysicalEdge(segment), !seen.insert(key).inserted { continue }
            if write != read { result[write] = segment }
            write += 1
        }
        result.removeLast(result.count - write)
        return result
    }

    private static func merge(_ previous: PhysicalDesignSnapshot.RouteSegment, _ current: PhysicalDesignSnapshot.RouteSegment,
        protectedPoints: borrowing Set<Point>, neighbors: borrowing [Point: Neighbors]) -> PhysicalDesignSnapshot.RouteSegment? {
        guard previous.layer == current.layer, previous.widthDBU == current.widthDBU,
              previous.isJumper == current.isJumper, let width = previous.widthDBU,
              previous.endpointExtensions == .init(beginDBU: width / 2, endDBU: width / 2),
              current.endpointExtensions == previous.endpointExtensions else { return nil }
        let horizontal = previous.y1 == previous.y2
        guard horizontal == (current.y1 == current.y2),
              horizontal ? previous.y1 == current.y1 : previous.x1 == current.x1,
              horizontal ? (previous.x2 > previous.x1) == (current.x2 > current.x1)
                         : (previous.y2 > previous.y1) == (current.y2 > current.y1) else { return nil }
        let forward = previous.x2 == current.x1 && previous.y2 == current.y1
        let reverse = current.x2 == previous.x1 && current.y2 == previous.y1
        guard forward || reverse else { return nil }
        let joint = Point(x: forward ? previous.x2 : previous.x1, y: forward ? previous.y2 : previous.y1, layer: previous.layer)
        guard !protectedPoints.contains(joint), neighbors[joint]?.branched != true else { return nil }
        var merged = previous
        if forward { merged.x2 = current.x2; merged.y2 = current.y2 }
        else { merged.x1 = current.x1; merged.y1 = current.y1 }
        return merged
    }

    private static func add(_ first: Int, _ second: Int) throws -> Int {
        let value = first.addingReportingOverflow(second)
        guard !value.overflow else { throw invalid("Generated path storage exceeds the index range.") }
        return value.partialValue
    }
    private static func multiply(_ first: Int, _ second: Int) throws -> Int {
        let value = first.multipliedReportingOverflow(by: second)
        guard !value.overflow else { throw invalid("Generated path work exceeds the index range.") }
        return value.partialValue
    }
    private static func invalid(_ message: String) -> PhysicalDesignSourceRouter.Failure {
        .init(code: "routing_generated_path_invalid", message: message)
    }
}
