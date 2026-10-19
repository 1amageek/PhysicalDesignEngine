import LEF
import LayoutIR
import MaskGeometry
import Testing
@testable import PhysicalDesignCore

@Suite("Native source spacing matrices", .timeLimit(.minutes(1)))
struct RoutingSpacingTests {
    private func rule(_ spacings: [Double] = [0.1, 0.15, 0.2, 0.2, 0.25, 0.3]) throws -> PhysicalDesignRoutingSpacingRule {
        try .init(source: .init(name: "m1", type: .routing, spacingTable: .init(
            parallelRunLengths: [-0.1, 0, 0.5], widthEntries: [
                .init(width: 0, spacings: Array(spacings[0..<3])),
                .init(width: 0.4, spacings: Array(spacings[3..<6]))])), units: 1000)
    }

    @Test(arguments: [(Int64(400), Int64(500), Int64(150)), (401, 500, 250),
                      (400, 501, 200), (401, 501, 300), (0, -200, 100),
                      (100, -100, 100), (100, 0, 100), (100, 1, 150)])
    func strictThresholds(_ values: (Int64, Int64, Int64)) throws {
        #expect(try rule().spacing(maximumWidth: values.0, parallelLength: values.1) == values.2)
    }

    @Test(arguments: ["missing", "mixed", "row", "order", "sub-dbu", "nonfinite", "negative", "spacing-order"])
    func invalidRule(_ scenario: String) {
        var source = LEFLayerDef(name: "m1", type: .routing, spacingTable: .init(parallelRunLengths: [0, 1], widthEntries: [.init(width: 0, spacings: [0.1, 0.2])]))
        switch scenario {
        case "missing": source.spacingTable = nil
        case "mixed": source.spacing = 0.1
        case "row": source.spacingTable?.widthEntries[0].spacings = [0.1]
        case "order": source.spacingTable?.parallelRunLengths = [1, 0]
        case "sub-dbu": source.spacingTable?.parallelRunLengths = [0, 0.0005]
        case "nonfinite": source.spacingTable?.widthEntries[0].spacings = [0.1, .infinity]
        case "negative": source.spacingTable?.widthEntries[0].spacings = [-0.1, 0.2]
        case "spacing-order": source.spacingTable?.widthEntries[0].spacings = [0.2, 0.1]
        default: Issue.record("Unknown fixture")
        }
        #expect(throws: PhysicalDesignTechnologyError.self) { _ = try PhysicalDesignRoutingSpacingRule(source: source, units: 1000) }
    }

    private func box(_ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32) -> Region {
        Region(layer: 2, polygons: [.init(layer: 2, datatype: 0, points: [
            .init(x: x, y: y), .init(x: x + width, y: y), .init(x: x + width, y: y + height),
            .init(x: x, y: y + height), .init(x: x, y: y)])])
    }

    @Test func actualWidthAndLength() throws {
        let object = try PhysicalDesignRoutingSpacingGeometry.compile(box(0, 350, 1000, 600))
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(box(0, 0, 400, 100), from: object, rule: rule(), minimum: 0))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(0, 0, 800, 100), from: object, rule: rule(), minimum: 0))
        let exact = try PhysicalDesignRoutingSpacingGeometry.compile(box(0, 400, 1000, 600))
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(box(0, 0, 800, 100), from: exact, rule: rule(), minimum: 0))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(0, 0, 800, 100), from: exact, rule: rule(), minimum: 301))
    }

    @Test func obstructionWidthDoesNotChangeFootprintOrParallelLength() throws {
        let obstacle = try PhysicalDesignRoutingSpacingGeometry.compile(box(0, 350, 1000, 600))
        let wire = box(0, 0, 1000, 100)
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(wire, from: obstacle, rule: rule(), minimum: 0))
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(wire, from: obstacle, rule: rule(), minimum: 0, obstacleWidthOverride: 100))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(wire, from: obstacle, rule: rule(), minimum: 251, obstacleWidthOverride: 100))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(0, -400, 1000, 600), from: obstacle, rule: rule(), minimum: 0, obstacleWidthOverride: 100))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(0, 300, 1000, 100), from: obstacle, rule: rule(), minimum: 0, obstacleWidthOverride: 100))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(0, 100, 1000, 100), from: obstacle, rule: rule(), minimum: 0, obstacleWidthOverride: 100))
        let reverse = try PhysicalDesignRoutingSpacingGeometry.compile(wire)
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(box(0, 350, 1000, 600), from: reverse, rule: rule(), minimum: 0, candidateWidthOverride: 100))
        #expect(throws: PhysicalDesignRoutingSourceError.self) {
            _ = try PhysicalDesignRoutingSpacingGeometry.separated(wire, from: obstacle, rule: rule(), minimum: 0, obstacleWidthOverride: 0)
        }
    }

    @Test func euclideanCornerAndContact() throws {
        let table = try PhysicalDesignRoutingSpacingRule(source: .init(name: "m1", type: .routing,
            spacingTable: .init(parallelRunLengths: [0], widthEntries: [.init(width: 0, spacings: [0.5])])), units: 1000)
        let corner = try PhysicalDesignRoutingSpacingGeometry.compile(box(400, 500, 100, 100))
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(box(0, 0, 100, 100), from: corner, rule: table, minimum: 0))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(0, 0, 100, 100), from: corner, rule: table, minimum: 501))
        let contact = try PhysicalDesignRoutingSpacingGeometry.compile(box(100, 0, 100, 100))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(0, 0, 100, 100), from: contact, rule: table, minimum: 0))
    }

    @Test func invalidGeometryAndBudget() {
        let diagonal = Region(layer: 2, polygons: [.init(layer: 2, datatype: 0, points: [
            .init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 0, y: 100), .init(x: 0, y: 0)])])
        #expect(throws: PhysicalDesignRoutingSourceError.self) { _ = try PhysicalDesignRoutingSpacingGeometry.compile(diagonal) }
        var budget = PhysicalDesignRoutingWorkBudget(caller: 1)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            _ = try PhysicalDesignRoutingSpacingObject.compile(box(0, 0, 100, 100), budget: &budget)
        }
    }

    @Test func concaveLocalWidthAndGap() throws {
        let shape = Region(layer: 2, polygons: [.init(layer: 2, datatype: 0, points: [
            .init(x: 0, y: 0), .init(x: 1000, y: 0), .init(x: 1000, y: 100),
            .init(x: 100, y: 100), .init(x: 100, y: 1000), .init(x: 0, y: 1000), .init(x: 0, y: 0)])])
        let rectangles = try PhysicalDesignRoutingSpacingGeometry.compile(shape)
        #expect(rectangles.rectangles.count == 2 && rectangles.rectangles.allSatisfy { $0.width == 100 })
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(box(300, 300, 600, 100),
            from: rectangles, rule: rule(), minimum: 0))
    }

    @Test func realEdgesInsideTheGapPreserveWideSpacing() throws {
        var metal = box(0, 0, 400, 300)
        metal.polygons.append(contentsOf: box(100, 300, 200, 200).polygons)
        let object = try PhysicalDesignRoutingSpacingGeometry.compile(metal)
        #expect(Set(object.rectangles.map(\.width)) == [200, 300])
        let table = try PhysicalDesignRoutingSpacingRule(source: .init(name: "m1", type: .routing,
            spacingTable: .init(parallelRunLengths: [0], widthEntries: [
                .init(width: 0, spacings: [0.1]), .init(width: 0.2, spacings: [0.4])])), units: 1000)
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(100, 600, 200, 100), from: object, rule: table, minimum: 0))
        #expect(try PhysicalDesignRoutingSpacingGeometry.separated(box(100, 700, 200, 100), from: object, rule: table, minimum: 0))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(0, 600, 100, 100), from: object, rule: table, minimum: 0))
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(box(100, 600, 200, 100), from: object, rule: table, minimum: 101))
    }

    @Test("sparse union rectangles and perimeter agree with exhaustive cell coverage", .timeLimit(.minutes(1)))
    func independentGridReference() throws {
        typealias Rectangle = PhysicalDesignRoutingSpacingObject.Rectangle
        for mask in 1..<512 {
            func filled(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < 3 && y >= 0 && y < 3 && mask & (1 << (y * 3 + x)) != 0 }
            func covered(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Bool {
                for y in y0..<y1 { for x in x0..<x1 where !filled(x, y) { return false } }
                return true
            }
            var region = Region(layer: 2), expected: Set<Rectangle> = [], expectedEdges: Set<[Int64]> = []
            for y in 0..<3 { for x in 0..<3 where filled(x, y) {
                region.polygons.append(contentsOf: box(Int32(x * 100), Int32(y * 100), 100, 100).polygons)
                if !filled(x - 1, y) { expectedEdges.insert([0, Int64(x * 100), Int64(y * 100), Int64((y + 1) * 100)]) }
                if !filled(x + 1, y) { expectedEdges.insert([1, Int64((x + 1) * 100), Int64(y * 100), Int64((y + 1) * 100)]) }
                if !filled(x, y - 1) { expectedEdges.insert([2, Int64(y * 100), Int64(x * 100), Int64((x + 1) * 100)]) }
                if !filled(x, y + 1) { expectedEdges.insert([3, Int64((y + 1) * 100), Int64(x * 100), Int64((x + 1) * 100)]) }
            } }
            for y0 in 0..<3 { for y1 in (y0 + 1)...3 { for x0 in 0..<3 { for x1 in (x0 + 1)...3 {
                guard covered(x0, y0, x1, y1), !covered(x0 - 1, y0, x1, y1), !covered(x0, y0, x1 + 1, y1),
                    !covered(x0, y0 - 1, x1, y1), !covered(x0, y0, x1, y1 + 1) else { continue }
                expected.insert(.init(minX: Int64(x0 * 100), minY: Int64(y0 * 100), maxX: Int64(x1 * 100), maxY: Int64(y1 * 100)))
            } } } }
            let actual = try PhysicalDesignRoutingSpacingGeometry.compile(region)
            #expect(Set(actual.rectangles) == expected, "Coverage mask \(mask)")
            var actualEdges: Set<[Int64]> = []
            for edge in actual.edges {
                for lower in stride(from: edge.lower, to: edge.upper, by: 100) {
                    actualEdges.insert([Int64(edge.side.rawValue), edge.position, lower, lower + 100])
                }
            }
            #expect(actualEdges == expectedEdges, "Perimeter mask \(mask)")
        }
    }

    @Test @MainActor func cancelledWorkspace() async {
        let task = Task {
            var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            return try PhysicalDesignRoutingSpacingObject.compile(box(0, 0, 100, 100), budget: &budget)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func expansionAndPairBudgetsAreCumulative() throws {
        var metal = box(0, 0, 400, 300)
        metal.polygons.append(contentsOf: box(100, 300, 200, 200).polygons)
        var measured = PhysicalDesignRoutingWorkBudget(caller: nil)
        _ = try PhysicalDesignRoutingSpacingObject.compile(metal, budget: &measured)
        let work = measured.checks
        var short = PhysicalDesignRoutingWorkBudget(caller: work - 1)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            _ = try PhysicalDesignRoutingSpacingObject.compile(metal, budget: &short)
        }
        #expect(short.checks > 10 && short.checks < work)
        var exact = PhysicalDesignRoutingWorkBudget(caller: work)
        _ = try PhysicalDesignRoutingSpacingObject.compile(metal, budget: &exact)
        #expect(exact.checks == work)

        var lookup = PhysicalDesignRoutingWorkBudget(caller: nil)
        let a = try PhysicalDesignRoutingSpacingObject.compile(box(0, 0, 100, 100), budget: &lookup)
        let b = try PhysicalDesignRoutingSpacingObject.compile(box(150, 0, 100, 100), budget: &lookup)
        let before = lookup.checks
        #expect(try !PhysicalDesignRoutingSpacingGeometry.separated(a, from: b, rule: rule(), minimum: 0, budget: &lookup))
        #expect(lookup.checks > before)
        var tooShort = PhysicalDesignRoutingWorkBudget(caller: lookup.checks - 1)
        let c = try PhysicalDesignRoutingSpacingObject.compile(box(0, 0, 100, 100), budget: &tooShort)
        let d = try PhysicalDesignRoutingSpacingObject.compile(box(150, 0, 100, 100), budget: &tooShort)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            _ = try PhysicalDesignRoutingSpacingGeometry.separated(c, from: d, rule: rule(), minimum: 0, budget: &tooShort)
        }
    }
}
