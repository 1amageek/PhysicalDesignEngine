import Foundation
import Testing
@testable import PhysicalDesignCore

@Suite("Explicit Clock conductor capture limits", .timeLimit(.minutes(1)))
struct ClockCaptureLimitsTests {
    private static let fields = ["maximumHierarchyOccurrences", "maximumHierarchyObjects", "maximumHierarchyGeometryPoints",
        "maximumHierarchyDepth", "maximumDecompositionInputEntries", "maximumDecompositionEdgeProbes",
        "maximumDecompositionOutputBands", "maximumTechnologyRecords", "maximumFootprints", "maximumContactProbes"]

    @Test func roundTripAndExactLowerConversion() throws {
        let limits = sample(), codec = PhysicalDesignJSONCodec()
        let decoded = try codec.decode(PhysicalDesignClockCaptureLimits.self, from: codec.encode(limits))
        #expect(decoded == limits)
        try decoded.validate()
        let lower = try decoded.lowerLimits()
        #expect(lower.hierarchy.maximumOccurrences == 1)
        #expect(lower.hierarchy.maximumObjects == 2)
        #expect(lower.hierarchy.maximumGeometryPoints == 3)
        #expect(lower.hierarchy.maximumDepth == 0)
        #expect(lower.decomposition.maximumInputEntries == 5)
        #expect(lower.decomposition.maximumEdgeProbes == 6)
        #expect(lower.decomposition.maximumOutputBands == 7)
        #expect(lower.maximumTechnologyRecords == 8)
        #expect(lower.maximumFootprints == 9)
        #expect(lower.maximumContactProbes == 10)
    }

    @Test(arguments: fields)
    func everyQuotaIsRequiredJSON(_ field: String) throws {
        let codec = PhysicalDesignJSONCodec()
        let original = try #require(JSONSerialization.jsonObject(with: codec.encode(sample())) as? [String: Any])
        for reason in ["missing", "null", "malformed"] {
            var object = original
            switch reason {
            case "missing": object.removeValue(forKey: field)
            case "null": object[field] = NSNull()
            default: object[field] = "quota"
            }
            let bytes = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) { try codec.decode(PhysicalDesignClockCaptureLimits.self, from: bytes) }
        }
    }

    @Test(arguments: fields)
    func invalidQuotaCannotReachLowerOwner(_ field: String) throws {
        let codec = PhysicalDesignJSONCodec()
        let original = try #require(JSONSerialization.jsonObject(with: codec.encode(sample())) as? [String: Any])
        let rejected = field == "maximumHierarchyDepth" ? [-1] : [0, -1]
        for value in rejected {
            var object = original
            object[field] = value
            let decoded = try codec.decode(PhysicalDesignClockCaptureLimits.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: PhysicalDesignClockTimingModelError.self) { try decoded.validate() }
            #expect(throws: PhysicalDesignClockTimingModelError.self) { try decoded.lowerLimits() }
        }
    }

    @Test func legacyClockSchemaRetainsNilCapturePolicy() async throws {
        var (_, _, model, reference) = try await CharacterizedNativeCTSTests().fixture(buffered: false)
        model.schemaVersion = 2
        model.numerics.captureLimits = nil
        let codec = PhysicalDesignJSONCodec()
        var object = try #require(JSONSerialization.jsonObject(with: codec.encode(model)) as? [String: Any])
        var numerics = try #require(object["numerics"] as? [String: Any])
        numerics.removeValue(forKey: "captureLimits")
        object["numerics"] = numerics
        let legacy = try codec.decode(PhysicalDesignClockTimingModel.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.schemaVersion == 2 && legacy.numerics.captureLimits == nil)
        try legacy.validate(against: reference)
        let retained = try codec.decode(PhysicalDesignClockTimingModel.self, from: codec.encode(legacy))
        #expect(retained.schemaVersion == 2 && retained.numerics.captureLimits == nil)
        #expect(retained.numerics.maximumProjectionRecords == legacy.numerics.maximumProjectionRecords)
        #expect(retained.numerics.maximumGeometryProbes == legacy.numerics.maximumGeometryProbes)
        var explicit = retained
        explicit.numerics.captureLimits = sample()
        #expect(throws: PhysicalDesignClockTimingModelError.self) { try explicit.validate(against: reference) }
        explicit.schemaVersion = 3
        try explicit.validate(against: reference)
    }

    private func sample() -> PhysicalDesignClockCaptureLimits {
        .init(maximumHierarchyOccurrences: 1, maximumHierarchyObjects: 2, maximumHierarchyGeometryPoints: 3,
            maximumHierarchyDepth: 0, maximumDecompositionInputEntries: 5, maximumDecompositionEdgeProbes: 6,
            maximumDecompositionOutputBands: 7, maximumTechnologyRecords: 8, maximumFootprints: 9, maximumContactProbes: 10)
    }
}
