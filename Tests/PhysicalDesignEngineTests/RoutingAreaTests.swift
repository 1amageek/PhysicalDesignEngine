import LayoutIR
import MaskGeometry
import Testing
@testable import PhysicalDesignCore

@Suite("Exact connected routing area", .timeLimit(.minutes(1)))
struct RoutingAreaTests {
    private func box(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> IRBoundary {
        .init(layer: 2, datatype: 0, points: [.init(x: x0, y: y0), .init(x: x1, y: y0),
            .init(x: x1, y: y1), .init(x: x0, y: y1), .init(x: x0, y: y0)])
    }

    private func areas(_ polygons: [IRBoundary]) throws -> [UInt64] {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        return try PhysicalDesignRoutingAreaGeometry.compile(Region(layer: 2, polygons: polygons), budget: &budget).map(\.areaDBU2).sorted()
    }

    @Test func squaredUnitsAndThresholdEquality() throws {
        let rule = try PhysicalDesignRoutingAreaRule(areaMicronsSquared: 0.083, unitsPerMicron: 1000)
        #expect(rule.minimumDBU2 == 83000)
        #expect(!rule.accepts(82999))
        #expect(rule.accepts(83000))
        #expect(rule.accepts(83001))
        #expect(try PhysicalDesignRoutingAreaRule(areaMicronsSquared: 0, unitsPerMicron: 1000).accepts(0))
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity, Double.leastNonzeroMagnitude, 0.0000005, 1e100])
    func invalidThreshold(_ value: Double) {
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try PhysicalDesignRoutingAreaRule(areaMicronsSquared: value, unitsPerMicron: 1000)
        }
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try PhysicalDesignRoutingAreaRule(areaMicronsSquared: 1, unitsPerMicron: 0)
        }
    }

    @Test func overlapsHolesAndPointContact() throws {
        let first = box(0, 0, 10, 10)
        #expect(try areas([first, first, box(5, 0, 15, 10)]) == [150])
        #expect(try areas([first, box(10, 0, 20, 10)]) == [200])
        #expect(try areas([first, box(10, 10, 20, 20)]) == [100, 100])
        #expect(try areas([box(0, 0, 30, 10), box(0, 20, 30, 30), box(0, 10, 10, 20), box(20, 10, 30, 20)]) == [800])
        #expect(try areas([]).isEmpty)
    }

    @Test func fullCoordinateDomainDoesNotUseInt64Area() throws {
        let width = UInt64(Int64(Int32.max) - Int64(Int32.min))
        #expect(try areas([box(.min, .min, .max, .max)]) == [width * width])
        #expect(width * width > UInt64(Int64.max))
    }

    @Test func independentCoverageAndFloodFill() throws {
        for mask in 1..<512 {
            var polygons: [IRBoundary] = []
            var cells: Set<Int> = []
            for index in 0..<9 where mask & (1 << index) != 0 {
                cells.insert(index)
                let x = Int32(index % 3 * 100), y = Int32(index / 3 * 100)
                polygons.append(box(x, y, x + 100, y + 100))
            }
            // Duplicate source pieces must not change the material area or connectivity.
            polygons.append(polygons[0])
            var expected: [UInt64] = []
            while let first = cells.min() {
                cells.remove(first)
                var queue = [first], count = 0
                while let index = queue.popLast() {
                    count += 1
                    let x = index % 3, y = index / 3
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where (0..<3).contains(nx) && (0..<3).contains(ny) {
                        let neighbour = ny * 3 + nx
                        if cells.remove(neighbour) != nil { queue.append(neighbour) }
                    }
                }
                expected.append(UInt64(count) * 10000)
            }
            #expect(try areas(polygons) == expected.sorted(), "Coverage mask \(mask)")
        }
    }

    @Test func oneCumulativeBudgetAndInvalidGeometry() throws {
        let region = Region(layer: 2, polygons: [box(0, 0, 10, 10), box(10, 0, 20, 10)])
        var measured = PhysicalDesignRoutingWorkBudget(caller: nil)
        let object = try PhysicalDesignRoutingSpacingObject.compile(region, budget: &measured, retainingMaterialBands: true)
        let before = measured.checks
        _ = try PhysicalDesignRoutingAreaGeometry.components(of: object, budget: &measured)
        #expect(measured.checks > before)
        var exact = PhysicalDesignRoutingWorkBudget(caller: measured.checks)
        _ = try PhysicalDesignRoutingAreaGeometry.compile(region, budget: &exact)
        var short = PhysicalDesignRoutingWorkBudget(caller: measured.checks - 1)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            _ = try PhysicalDesignRoutingAreaGeometry.compile(region, budget: &short)
        }
        var invalid = PhysicalDesignRoutingWorkBudget(caller: nil)
        let triangle = IRBoundary(layer: 2, datatype: 0, points: [.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 0, y: 10)])
        #expect(throws: PhysicalDesignRoutingSourceError.self) {
            _ = try PhysicalDesignRoutingAreaGeometry.compile(Region(layer: 2, polygons: [triangle]), budget: &invalid)
        }
    }

    @Test func absentFactsAreNotZeroArea() throws {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let object = try PhysicalDesignRoutingSpacingObject.compile(Region(layer: 2, polygons: [box(0, 0, 10, 10)]), budget: &budget)
        #expect(object.materialBands == nil)
        #expect(throws: PhysicalDesignRoutingSourceError.self) {
            _ = try PhysicalDesignRoutingAreaGeometry.components(of: object, budget: &budget)
        }
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try PhysicalDesignRoutingAreaRule(areaMicronsSquared: Double.leastNonzeroMagnitude, unitsPerMicron: 1)
        }
    }

    @Test @MainActor func cancellationIsNotAZeroArea() async {
        let region = Region(layer: 2, polygons: [box(0, 0, 10, 10)])
        let task = Task {
            var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            return try PhysicalDesignRoutingAreaGeometry.compile(region, budget: &budget)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
