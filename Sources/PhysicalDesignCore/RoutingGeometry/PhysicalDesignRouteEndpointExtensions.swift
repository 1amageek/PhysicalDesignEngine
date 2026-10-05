/// Signed outward distances from the ordered original centerline endpoints, in DBU.
public struct PhysicalDesignRouteEndpointExtensions: Sendable, Hashable, Codable {
    public enum GeometryError: Error, Sendable, Equatable {
        case unqualifiedGeometry
        case unsupportedWidth
        case nonRectilinearGeometry
        case coordinateOverflow
        case nonPositiveFootprint
        case invalidRetraction
    }

    public let beginDBU: Int64
    public let endDBU: Int64

    public init(beginDBU: Int64, endDBU: Int64) {
        self.beginDBU = beginDBU
        self.endDBU = endDBU
    }

    public func footprint(of segment: PhysicalDesignSnapshot.RouteSegment) throws(GeometryError) -> PhysicalDesignSnapshot.Rect {
        guard let width = segment.widthDBU else { throw .unqualifiedGeometry }
        guard width > 0, width.isMultiple(of: 2) else { throw .unsupportedWidth }
        let horizontal = segment.y1 == segment.y2
        guard horizontal != (segment.x1 == segment.x2) else { throw .nonRectilinearGeometry }
        func add(_ value: Int64, _ delta: Int64) throws(GeometryError) -> Int64 {
            let result = value.addingReportingOverflow(delta)
            guard !result.overflow else { throw .coordinateOverflow }
            return result.partialValue
        }
        func subtract(_ value: Int64, _ delta: Int64) throws(GeometryError) -> Int64 {
            let result = value.subtractingReportingOverflow(delta)
            guard !result.overflow else { throw .coordinateOverflow }
            return result.partialValue
        }
        let first = horizontal ? segment.x1 : segment.y1
        let last = horizontal ? segment.x2 : segment.y2
        let length = try first < last ? subtract(last, first) : subtract(first, last)
        guard beginDBU > -length, endDBU > -length else { throw .invalidRetraction }
        let lower = try first < last ? subtract(first, beginDBU) : subtract(last, endDBU)
        let upper = try first < last ? add(last, endDBU) : add(first, beginDBU)
        let lateral = horizontal ? segment.y1 : segment.x1
        let lateralMin = try subtract(lateral, width / 2)
        let lateralMax = try add(lateral, width / 2)
        guard upper > lower else { throw .nonPositiveFootprint }
        guard [segment.x1, segment.y1, segment.x2, segment.y2, lower, upper, lateralMin, lateralMax]
            .allSatisfy({ Int32(exactly: $0) != nil }) else { throw .coordinateOverflow }
        return horizontal
            ? .init(x: lower, y: lateralMin, width: upper - lower, height: width)
            : .init(x: lateralMin, y: lower, width: width, height: upper - lower)
    }
}

extension PhysicalDesignSnapshot.RouteSegment {
    public func qualifiedFootprint() throws(PhysicalDesignRouteEndpointExtensions.GeometryError) -> PhysicalDesignSnapshot.Rect {
        guard let endpointExtensions else { throw .unqualifiedGeometry }
        return try endpointExtensions.footprint(of: self)
    }
}
