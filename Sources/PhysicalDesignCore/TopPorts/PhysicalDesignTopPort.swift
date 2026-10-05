import DEF

/// Exact source top-port surface and placement, in the owning snapshot's DBU scale.
public struct PhysicalDesignTopPort: Sendable, Hashable, Codable {
    public enum GeometryError: Error, Sendable, Equatable {
        case invalidRectangle
        case coordinateOverflow
        case unplacedPort
    }

    public let rectangle: PhysicalDesignSnapshot.Rect
    public let layer: Int
    public let placementX: Int64
    public let placementY: Int64
    public let orientation: DEFOrientation
    public let placementStatus: DEFComponent.PlacementStatus
    public let use: DEFSpecialNet.NetUse

    public init(rectangle: PhysicalDesignSnapshot.Rect, layer: Int,
                placementX: Int64, placementY: Int64, orientation: DEFOrientation,
                placementStatus: DEFComponent.PlacementStatus, use: DEFSpecialNet.NetUse) {
        self.rectangle = rectangle
        self.layer = layer
        self.placementX = placementX
        self.placementY = placementY
        self.orientation = orientation
        self.placementStatus = placementStatus
        self.use = use
    }

    public func worldRectangle() throws(GeometryError) -> PhysicalDesignSnapshot.Rect {
        guard rectangle.width > 0, rectangle.height > 0 else { throw .invalidRectangle }
        guard placementStatus != .unplaced else { throw .unplacedPort }
        let (right, overflowX) = rectangle.x.addingReportingOverflow(rectangle.width)
        let (top, overflowY) = rectangle.y.addingReportingOverflow(rectangle.height)
        guard !overflowX, !overflowY,
              [rectangle.x, rectangle.y, right, top, placementX, placementY].allSatisfy({ Int32(exactly: $0) != nil }) else {
            throw .coordinateOverflow
        }
        // Int32 source coordinates with orthogonal +/-1 matrices fit Int64.
        // Unlike macro placement, a top-port pose rotates around its source origin.
        let matrix: (Int64, Int64, Int64, Int64)
        switch orientation {
        case .n: matrix = (1, 0, 0, 1)
        case .s: matrix = (-1, 0, 0, -1)
        case .e: matrix = (0, 1, -1, 0)
        case .w: matrix = (0, -1, 1, 0)
        case .fn: matrix = (-1, 0, 0, 1)
        case .fs: matrix = (1, 0, 0, -1)
        case .fe: matrix = (0, -1, -1, 0)
        case .fw: matrix = (0, 1, 1, 0)
        }
        let corners = [(rectangle.x, rectangle.y), (right, rectangle.y), (rectangle.x, top), (right, top)]
        let xs = corners.map { matrix.0 * $0.0 + matrix.1 * $0.1 + placementX }
        let ys = corners.map { matrix.2 * $0.0 + matrix.3 * $0.1 + placementY }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              [minX, maxX, minY, maxY].allSatisfy({ Int32(exactly: $0) != nil }) else { throw .coordinateOverflow }
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
