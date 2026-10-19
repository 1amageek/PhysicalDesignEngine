import Foundation
import LayoutIR
import MaskGeometry
import Testing
@testable import PhysicalDesignCore

@Suite("Generated collinear route normalization", .timeLimit(.minutes(1)))
struct GeneratedRouteNormalizationTests {
    typealias Segment = PhysicalDesignSnapshot.RouteSegment
    typealias Point = PhysicalDesignGeneratedRouteNormalizer.Point

    @Test(arguments: [false, true])
    func orderedAndReverseReconstructionPreserveExactMetal(reverse: Bool) throws {
        var input = (0..<1000).map { index in wire("opaque-\(index)", Int64(index * 10), Int64((index + 1) * 10)) }
        if reverse { input.reverse() }
        let before = input
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let output = try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<input.count], protectedPoints: [], budget: &budget)
        #expect(input == before && output.count == 1)
        #expect(output[0].id == before[0].id && output[0].x1 == 0 && output[0].x2 == 10000)
        #expect(output[0].endpointExtensions == .init(beginDBU: 50, endDBU: 50))
        try sameMetalAndLength(before, output)
        var repeated = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<input.count], protectedPoints: [], budget: &repeated) == output)
        let descending: [Segment] = (0..<10).map { index -> Segment in
            let first: Int64 = 100 - Int64(index) * 10
            let last: Int64 = first - 10
            return Segment(id: "vertical-\(index)", layer: 2, x1: 0, y1: first, x2: 0, y2: last,
                widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))
        }
        let vertical = reverse ? Array(descending.reversed()) : descending
        var verticalBudget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let verticalOutput = try PhysicalDesignGeneratedRouteNormalizer.normalize(vertical, paths: [0..<10], protectedPoints: [], budget: &verticalBudget)
        #expect(verticalOutput.count == 1 && verticalOutput[0].y1 == 100 && verticalOutput[0].y2 == 0)
        try sameMetalAndLength(vertical, verticalOutput)
    }

    @Test func branchesViaTerminalsAndPathRangesStayExplicit() throws {
        let input = [wire("a", 0, 100), wire("b", 100, 200), wire("c", 200, 300), wire("d", 300, 400),
            .init(id: "branch", layer: 2, x1: 200, y1: 0, x2: 200, y2: 100, widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))]
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let output = try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<4, 4..<5],
            protectedPoints: [.init(x: 100, y: 0, layer: 2), .init(x: 300, y: 0, layer: 2)], budget: &budget)
        // x100 and x300 represent terminal/VIA anchors; x200 is discovered from three unique neighbors.
        #expect(output == input)
        try sameMetalAndLength(input, output)
        var separate = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try PhysicalDesignGeneratedRouteNormalizer.normalize(Array(input.prefix(2)), paths: [0..<1, 1..<2],
            protectedPoints: [], budget: &separate) == Array(input.prefix(2)))
        let duplicatePaths = [wire("p0", 0, 100), wire("p1", 100, 200), wire("q0", 0, 100), wire("q1", 100, 200)]
        var duplicates = PhysicalDesignRoutingWorkBudget(caller: nil)
        let compact = try PhysicalDesignGeneratedRouteNormalizer.normalize(duplicatePaths, paths: [0..<2, 2..<4],
            protectedPoints: [], budget: &duplicates)
        #expect(compact.count == 1 && compact.map(\.id) == ["p0"])
        try sameMetalAndLength(duplicatePaths, compact, preservingRecordLength: false)
        #expect(compact[0].x2 - compact[0].x1 == 200)
    }

    @Test func actualCTSSharedTrunkExportsOnePhysicalWire() throws {
        let first = Segment(id: "route_net-4_segment_0", layer: 2,
            x1: 230, y1: 1190, x2: 1610, y2: 1190, widthDBU: 140,
            endpointExtensions: .init(beginDBU: 70, endDBU: 70))
        var repeated = first; repeated.id = "route_net-4_segment_1998"
        let anchors: Set<Point> = [.init(x: 230, y: 1190, layer: 2), .init(x: 1610, y: 1190, layer: 2)]
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let output = try PhysicalDesignGeneratedRouteNormalizer.normalize([first, repeated], paths: [0..<1, 1..<2],
            protectedPoints: anchors, budget: &budget)
        #expect(output == [first])
        try sameMetalAndLength([first, repeated], output, preservingRecordLength: false)
        #expect(output.reduce(Int64(0)) { $0 + abs($1.x2 - $1.x1) + abs($1.y2 - $1.y1) } == 1380)
        let snapshot = PhysicalDesignSnapshot(topCell: "shared-trunk", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 2000, height: 2000), core: .init(x: 0, y: 0, width: 2000, height: 2000),
            nets: [.init(id: "net-4", pinIDs: [], isClock: true)],
            routes: [.init(id: "route_net-4", netID: "net-4", segments: output, defStatus: .routed)])
        let def = try PhysicalDesignDEFWriter().write(snapshot)
        #expect(def.components(separatedBy: "( 230 1190 70 ) ( 1610 1190 70 )").count - 1 == 1)
        let codec = PhysicalDesignJSONCodec()
        #expect(try codec.decode(PhysicalDesignSnapshot.self, from: codec.encode(snapshot)) == snapshot)
        var exact = PhysicalDesignRoutingWorkBudget(caller: budget.checks)
        #expect(try PhysicalDesignGeneratedRouteNormalizer.normalize([first, repeated], paths: [0..<1, 1..<2],
            protectedPoints: anchors, budget: &exact) == output)
        var short = PhysicalDesignRoutingWorkBudget(caller: budget.checks - 1)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try PhysicalDesignGeneratedRouteNormalizer.normalize([first, repeated], paths: [0..<1, 1..<2],
                protectedPoints: anchors, budget: &short)
        }
    }

    @Test func duplicateIdentityKeepsOrientationAttributesAndCustomMetal() throws {
        let first = wire("first", 0, 100)
        var reverse = first; reverse.id = "reverse-copy"; reverse.x1 = 100; reverse.x2 = 0
        var wide = first; wide.id = "wide"; wide.widthDBU = 140; wide.endpointExtensions = .init(beginDBU: 70, endDBU: 70)
        var jumper = first; jumper.id = "jumper"; jumper.isJumper = true
        var layer = first; layer.id = "layer"; layer.layer = 3
        var custom = first; custom.id = "custom"; custom.endpointExtensions = .init(beginDBU: 0, endDBU: 50)
        var customCopy = custom; customCopy.id = "custom-copy"
        var partial = first; partial.id = "partial"; partial.x1 = 50; partial.x2 = 150
        let input = [first, reverse, wide, jumper, layer, custom, customCopy, partial]
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let output = try PhysicalDesignGeneratedRouteNormalizer.normalize(input,
            paths: input.indices.map { $0..<($0 + 1) }, protectedPoints: [], budget: &budget)
        #expect(output == [first, wide, jumper, layer, custom, customCopy, partial])
        try sameMetalAndLength(input, output, preservingRecordLength: false)
    }

    @Test func attributesCapsTurnsAndUnselectedGeometryArePreserved() throws {
        var input = [wire("normal", 0, 100), wire("wide", 100, 200, width: 140),
            wire("jumper", 200, 300, width: 140), wire("other-layer", 300, 400, width: 140),
            wire("custom", 400, 500, width: 140), wire("reverse", 600, 500, width: 140)]
        input[2].isJumper = true
        input[3].layer = 3
        input[4].endpointExtensions = .init(beginDBU: 0, endDBU: -10)
        let retained = PhysicalDesignSnapshot.Route(id: "retained", netID: "unselected", segments: [input[4]], defStatus: .fixed)
        let before = input
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let output = try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<input.count], protectedPoints: [], budget: &budget)
        #expect(output == before && input == before && retained.segments == [before[4]] && retained.defStatus == .fixed)
        try sameMetalAndLength(before, output)
        let turn = [wire("horizontal", 0, 100), Segment(id: "vertical", layer: 2, x1: 100, y1: 0, x2: 100, y2: 100,
            widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))]
        var turnBudget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try PhysicalDesignGeneratedRouteNormalizer.normalize(turn, paths: [0..<2], protectedPoints: [], budget: &turnBudget) == turn)
    }

    @Test func quotasRemainCumulativeAndMalformedOwnershipCannotPass() throws {
        let input = (0..<20).map { index in wire("wire-\(index)", Int64(index * 10), Int64((index + 1) * 10)) }
        var measured = PhysicalDesignRoutingWorkBudget(caller: nil)
        _ = try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<20], protectedPoints: [], budget: &measured)
        let first = measured.checks
        _ = try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<20], protectedPoints: [], budget: &measured)
        #expect(measured.checks == first * 2)
        var exact = PhysicalDesignRoutingWorkBudget(caller: measured.checks)
        for _ in 0..<2 { _ = try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<20], protectedPoints: [], budget: &exact) }
        #expect(exact.checks == measured.checks)
        var short = PhysicalDesignRoutingWorkBudget(caller: measured.checks - 1)
        _ = try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<20], protectedPoints: [], budget: &short)
        do {
            _ = try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [0..<20], protectedPoints: [], budget: &short)
            Issue.record("Normalizer reset the cumulative quota")
        } catch let error as PhysicalDesignSourceRouter.Failure { #expect(error.code == "routing_candidate_budget_exhausted") }
        var invalid = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try PhysicalDesignGeneratedRouteNormalizer.normalize(input, paths: [1..<20], protectedPoints: [], budget: &invalid)
        }
        var duplicate = input; duplicate[1].id = duplicate[0].id
        var duplicateBudget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try PhysicalDesignGeneratedRouteNormalizer.normalize(duplicate, paths: [0..<20], protectedPoints: [], budget: &duplicateBudget)
        }
    }

    @Test func cancellationReturnsNoNormalizedResult() async {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            return try PhysicalDesignGeneratedRouteNormalizer.normalize([wire("wire", 0, 100)], paths: [0..<1], protectedPoints: [], budget: &budget)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func wire(_ id: String, _ first: Int64, _ last: Int64, width: Int64 = 100) -> Segment {
        .init(id: id, layer: 2, x1: first, y1: 0, x2: last, y2: 0, widthDBU: width,
            endpointExtensions: .init(beginDBU: width / 2, endDBU: width / 2))
    }

    private func sameMetalAndLength(_ original: [Segment], _ normalized: [Segment], preservingRecordLength: Bool = true) throws {
        func facts(_ segments: [Segment]) throws -> (regions: [Int: Region], length: Int64) {
            var regions: [Int: Region] = [:], length: Int64 = 0
            for segment in segments {
                let rectangle = try segment.qualifiedFootprint()
                let shape = IRBoundary(layer: Int16(segment.layer), datatype: 0, points: [
                    .init(x: Int32(rectangle.x), y: Int32(rectangle.y)), .init(x: Int32(rectangle.maxX), y: Int32(rectangle.y)),
                    .init(x: Int32(rectangle.maxX), y: Int32(rectangle.maxY)), .init(x: Int32(rectangle.x), y: Int32(rectangle.maxY)),
                    .init(x: Int32(rectangle.x), y: Int32(rectangle.y))])
                let region = Region(layer: Int16(segment.layer), polygons: [shape])
                regions[segment.layer] = try (regions[segment.layer] ?? Region(layer: Int16(segment.layer))).union(region)
                length += abs(segment.x2 - segment.x1) + abs(segment.y2 - segment.y1)
            }
            return (regions, length)
        }
        let before = try facts(original), after = try facts(normalized)
        if preservingRecordLength { #expect(before.length == after.length) }
        #expect(Set(before.regions.keys) == Set(after.regions.keys))
        for (layer, metal) in before.regions { #expect(try metal.symmetricDifference(#require(after.regions[layer])).isEmpty) }
    }
}
