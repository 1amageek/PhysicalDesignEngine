import Foundation
import LayoutIR
import MaskGeometry
import Testing
@testable import PhysicalDesignCore

@Suite("Staged spacing geometry work admission", .timeLimit(.minutes(1)))
struct RoutingSpacingBudgetTests {
    @Test(arguments: [false, true])
    func segmentedInventoryPreservesGeometryAndExactQuota(teeth: Bool) throws {
        let region = segmented(teeth: teeth)
        #expect(region.polygons.count == 4521 && region.polygons.reduce(0) { $0 + $1.points.count + 1 } == 27126)
        var measured = PhysicalDesignRoutingWorkBudget(caller: nil)
        let actual = try PhysicalDesignRoutingSpacingObject.compile(region, budget: &measured, retainingMaterialBands: true)
        try verify(actual, teeth: teeth)
        #expect(measured.checks > 27126 && measured.checks <= measured.capacity)

        var exact = PhysicalDesignRoutingWorkBudget(caller: measured.checks)
        let repeated = try PhysicalDesignRoutingSpacingObject.compile(region, budget: &exact, retainingMaterialBands: true)
        try verify(repeated, teeth: teeth)
        #expect(exact.checks == measured.checks && exact.capacity == measured.capacity)
        var short = PhysicalDesignRoutingWorkBudget(caller: measured.checks - 1)
        do {
            _ = try PhysicalDesignRoutingSpacingObject.compile(region, budget: &short, retainingMaterialBands: true)
            Issue.record("A phase reset or bypassed the cumulative work limit")
        } catch let error as PhysicalDesignSourceRouter.Failure {
            #expect(error.code == "routing_candidate_budget_exhausted")
        }
        #expect(short.checks < measured.checks)
    }

    @Test func cancellationCannotPublishLargeGeometry() async throws {
        let region = segmented(teeth: true)
        var callbacks = 0
        var run = PhysicalDesignRoutingWorkBudget(caller: nil)
        do {
            _ = try PhysicalDesignRoutingSpacingObject.compile(region, budget: &run, retainingMaterialBands: true,
                additionalCancellationCheck: { callbacks += 1; return callbacks >= 8 })
            Issue.record("Lower decomposition ignored cancellation after work began")
        } catch RectilinearDecompositionError.cancelled { }
        #expect(callbacks >= 8 && run.checks > 27126)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            return try PhysicalDesignRoutingSpacingObject.compile(region, budget: &budget, retainingMaterialBands: true)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func segmented(teeth: Bool) -> Region {
        var region = Region(layer: 2)
        for index in 0..<4521 {
            let x = Int32(index * 10), height: Int32 = teeth && index.isMultiple(of: 2) ? 200 : 100
            region.polygons.append(.init(layer: 2, datatype: 0, points: [
                .init(x: x, y: 0), .init(x: x + 10, y: 0), .init(x: x + 10, y: height),
                .init(x: x, y: height), .init(x: x, y: 0)]))
        }
        return region
    }

    private func verify(_ object: PhysicalDesignRoutingSpacingObject, teeth: Bool) throws {
        typealias Rectangle = PhysicalDesignRoutingSpacingObject.Rectangle
        var expected: Set<Rectangle> = [.init(minX: 0, minY: 0, maxX: 45210, maxY: 100)]
        if teeth {
            for index in stride(from: 0, to: 4521, by: 2) {
                let x = Int64(index * 10)
                expected.insert(.init(minX: x, minY: 0, maxX: x + 10, maxY: 200))
            }
        }
        #expect(Set(object.rectangles) == expected)
        let bands = try #require(object.materialBands)
        let area = bands.reduce(Int64(0)) { $0 + ($1.maxX - $1.minX) * ($1.maxY - $1.minY) }
        // Independently count tiled source coverage: every base tile, plus each raised even tile.
        #expect(area == 4521 * 10 * 100 + (teeth ? 2261 * 10 * 100 : 0))
        #expect(!object.edges.isEmpty)
    }
}
