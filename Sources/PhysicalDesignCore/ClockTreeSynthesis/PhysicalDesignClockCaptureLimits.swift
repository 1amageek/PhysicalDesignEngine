import LayoutIR
import LayoutVerify
import MaskGeometry

/// Serializable resource policy for the existing conductor capture implementation.
public struct PhysicalDesignClockCaptureLimits: Sendable, Equatable, Codable {
    public var maximumHierarchyOccurrences: Int
    public var maximumHierarchyObjects: Int
    public var maximumHierarchyGeometryPoints: Int
    public var maximumHierarchyDepth: Int
    /// Polygon count plus point count after fixed-VIA expansion.
    public var maximumDecompositionInputEntries: Int
    public var maximumDecompositionEdgeProbes: Int
    public var maximumDecompositionOutputBands: Int
    public var maximumTechnologyRecords: Int
    public var maximumFootprints: Int
    /// Candidate footprint pairs and pin-band/footprint tests, including misses.
    public var maximumContactProbes: Int

    public init(maximumHierarchyOccurrences: Int, maximumHierarchyObjects: Int, maximumHierarchyGeometryPoints: Int,
                maximumHierarchyDepth: Int, maximumDecompositionInputEntries: Int, maximumDecompositionEdgeProbes: Int,
                maximumDecompositionOutputBands: Int, maximumTechnologyRecords: Int,
                maximumFootprints: Int, maximumContactProbes: Int) {
        self.maximumHierarchyOccurrences = maximumHierarchyOccurrences
        self.maximumHierarchyObjects = maximumHierarchyObjects
        self.maximumHierarchyGeometryPoints = maximumHierarchyGeometryPoints
        self.maximumHierarchyDepth = maximumHierarchyDepth
        self.maximumDecompositionInputEntries = maximumDecompositionInputEntries
        self.maximumDecompositionEdgeProbes = maximumDecompositionEdgeProbes
        self.maximumDecompositionOutputBands = maximumDecompositionOutputBands
        self.maximumTechnologyRecords = maximumTechnologyRecords
        self.maximumFootprints = maximumFootprints
        self.maximumContactProbes = maximumContactProbes
    }

    public func validate() throws {
        guard maximumHierarchyDepth >= 0,
              [maximumHierarchyOccurrences, maximumHierarchyObjects, maximumHierarchyGeometryPoints, maximumDecompositionInputEntries,
               maximumDecompositionEdgeProbes, maximumDecompositionOutputBands, maximumTechnologyRecords,
               maximumFootprints, maximumContactProbes].allSatisfy({ $0 > 0 }) else {
            throw PhysicalDesignClockTimingModelError.invalidModel("conductor capture limits")
        }
    }

    func lowerLimits() throws -> LayoutConductorCaptureLimits {
        try validate()
        return .init(hierarchy: .init(maximumOccurrences: maximumHierarchyOccurrences,
                                     maximumObjects: maximumHierarchyObjects,
                                     maximumGeometryPoints: maximumHierarchyGeometryPoints,
                                     maximumDepth: maximumHierarchyDepth),
                     decomposition: .init(maximumInputEntries: maximumDecompositionInputEntries,
                                          maximumEdgeProbes: maximumDecompositionEdgeProbes,
                                          maximumOutputBands: maximumDecompositionOutputBands),
                     maximumTechnologyRecords: maximumTechnologyRecords,
                     maximumFootprints: maximumFootprints,
                     maximumContactProbes: maximumContactProbes)
    }
}
