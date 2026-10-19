import Testing
@testable import PhysicalDesignCore

@Suite("Finite source-static event graph", .timeLimit(.minutes(1)))
struct RoutingEventGraphTests {
    private typealias Node = PhysicalDesignRoutingSearch.Node

    @Test func admittedDetourAndDisconnectedNodeHaveExactDistances() throws {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var graph = try PhysicalDesignRoutingEventGraph(xCount: 3, yCount: 3, layers: [2], defaultMasterCount: 0, budget: &budget)
        // The geometry owner omitted the blocked middle row; the graph must follow the admitted detour.
        let path = [node(0, 0), node(0, 1), node(0, 2), node(1, 2), node(2, 2), node(2, 1), node(2, 0)]
        for index in 1..<path.count {
            try graph.addUndirected(from: path[index - 1], to: path[index], contact: nil, budget: &budget)
        }
        let distances = try graph.reverseDistances(targets: [path.last!], budget: &budget)
        for (offset, point) in path.enumerated() {
            #expect(distances[try graph.index(of: point)] == path.count - 1 - offset)
        }
        #expect(distances[try graph.index(of: node(1, 1))] == -1)
        #expect(distances[try graph.index(of: node(1, 0))] == -1)

        let multiple = try graph.reverseDistances(targets: [path.first!, path.last!, path.last!], budget: &budget)
        for (offset, point) in path.enumerated() {
            #expect(multiple[try graph.index(of: point)] == min(offset, path.count - 1 - offset))
        }
        let empty = try graph.reverseDistances(targets: [], budget: &budget)
        #expect(empty.allSatisfy { $0 == -1 })
    }

    @Test func parallelContactsKeepIdentityInsertionOrderAndBothDirections() throws {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var graph = try PhysicalDesignRoutingEventGraph(xCount: 1, yCount: 1, layers: [2, 4], defaultMasterCount: 2, budget: &budget)
        let lower = node(0, 0), upper = node(0, 0, layer: 4)
        try graph.addUndirected(from: lower, to: upper, contact: 7, budget: &budget)
        try graph.addUndirected(from: lower, to: upper, contact: 11, budget: &budget)
        for source in [lower, upper] {
            var cursor = try graph.firstEdge(from: source, budget: &budget)
            var contacts: [Int?] = [], destinations: [Node] = []
            while let index = cursor {
                let edge = try graph.edge(at: index, budget: &budget)
                contacts.append(edge.contact)
                destinations.append(edge.destination)
                cursor = edge.next
            }
            #expect(contacts == [7, 11])
            #expect(destinations == [source == lower ? upper : lower, source == lower ? upper : lower])
        }
        let distances = try graph.reverseDistances(targets: [upper], budget: &budget)
        #expect(distances[try graph.index(of: lower)] == 1)
        #expect(distances[try graph.index(of: upper)] == 0)
    }

    @Test func everyAdmittedEdgeSatisfiesDistanceConsistency() throws {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var graph = try PhysicalDesignRoutingEventGraph(xCount: 4, yCount: 1, layers: [8], defaultMasterCount: 0, budget: &budget)
        let nodes = (0..<4).map { node($0, 0, layer: 8) }
        for index in 1..<nodes.count {
            try graph.addUndirected(from: nodes[index - 1], to: nodes[index], contact: nil, budget: &budget)
        }
        let distances = try graph.reverseDistances(targets: [nodes[0], nodes[3]], budget: &budget)
        #expect(distances == [0, 1, 1, 0])
        for source in nodes {
            let distance = distances[try graph.index(of: source)]
            var cursor = try graph.firstEdge(from: source, budget: &budget)
            while let index = cursor {
                let edge = try graph.edge(at: index, budget: &budget)
                let other = distances[try graph.index(of: edge.destination)]
                #expect(distance <= other + 1 && other <= distance + 1)
                cursor = edge.next
            }
        }
    }

    @Test func denseIndexingIsBijectiveAndRejectsForeignNodesAndEdges() throws {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let graph = try PhysicalDesignRoutingEventGraph(xCount: 3, yCount: 2, layers: [8, 2], defaultMasterCount: 0, budget: &budget)
        var indices: Set<Int> = []
        for layer in [8, 2] { for x in 0..<3 { for y in 0..<2 {
            indices.insert(try graph.index(of: node(x, y, layer: layer)))
        } } }
        #expect(indices == Set(0..<12))
        for invalid in [node(-1, 0), node(3, 0), node(0, -1), node(0, 2), node(0, 0, layer: 3)] {
            expectFailure("routing_coordinate_overflow") { _ = try graph.index(of: invalid) }
        }
        expectFailure("routing_coordinate_overflow") { _ = try graph.edge(at: 0, budget: &budget) }
        expectFailure("routing_coordinate_overflow") { _ = try graph.edge(at: -1, budget: &budget) }
        expectFailure("routing_coordinate_overflow") {
            _ = try graph.reverseDistances(targets: [node(0, 0, layer: 3)], budget: &budget)
        }
    }

    @Test func invalidDimensionsAndEntryOrByteOverflowFailBeforeAllocation() {
        for dimensions in [(0, 1, 0), (1, -1, 0), (1, 1, -1), (Int.max, 2, 0),
                           (Int.max / 4, 1, 0), (1, 1, Int.max)] {
            var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            expectFailure("routing_coordinate_overflow") {
                _ = try PhysicalDesignRoutingEventGraph(xCount: dimensions.0, yCount: dimensions.1,
                    layers: [2], defaultMasterCount: dimensions.2, budget: &budget)
            }
            #expect(budget.checks == 0)
        }
        for layers in [[], [2, 2]] {
            var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            expectFailure("routing_coordinate_overflow") {
                _ = try PhysicalDesignRoutingEventGraph(xCount: 1, yCount: 1, layers: layers, defaultMasterCount: 0, budget: &budget)
            }
        }
    }

    @Test func edgeAllowanceRefusalDoesNotPublishHalfAnEdge() throws {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var graph = try PhysicalDesignRoutingEventGraph(xCount: 1, yCount: 1, layers: [2, 4], defaultMasterCount: 0, budget: &budget)
        let a = node(0, 0), b = node(0, 0, layer: 4)
        try graph.addUndirected(from: a, to: b, contact: 0, budget: &budget)
        try graph.addUndirected(from: a, to: b, contact: 1, budget: &budget)
        expectFailure("routing_candidate_budget_exhausted") {
            try graph.addUndirected(from: a, to: b, contact: 2, budget: &budget)
        }
        for source in [a, b] {
            var cursor = try graph.firstEdge(from: source, budget: &budget)
            var contacts: [Int?] = []
            while let index = cursor {
                let edge = try graph.edge(at: index, budget: &budget)
                contacts.append(edge.contact)
                cursor = edge.next
            }
            #expect(contacts == [0, 1])
        }
        expectFailure("routing_coordinate_overflow") { try graph.addUndirected(from: a, to: a, contact: nil, budget: &budget) }
        expectFailure("routing_coordinate_overflow") { try graph.addUndirected(from: a, to: b, contact: -1, budget: &budget) }
    }

    @Test func exactCumulativeQuotaPassesAndOneLessCannotReturnDistances() throws {
        let measured = try exercise(caller: nil)
        let exact = try exercise(caller: measured.checks)
        #expect(exact.checks == measured.checks && exact.capacity == measured.capacity)
        expectFailure("routing_candidate_budget_exhausted") { _ = try exercise(caller: measured.checks - 1) }

        var initial = PhysicalDesignRoutingWorkBudget(caller: nil)
        _ = try PhysicalDesignRoutingEventGraph(xCount: 2, yCount: 1, layers: [2], defaultMasterCount: 0, budget: &initial)
        var short = PhysicalDesignRoutingWorkBudget(caller: initial.checks + 7)
        var graph = try PhysicalDesignRoutingEventGraph(xCount: 2, yCount: 1, layers: [2], defaultMasterCount: 0, budget: &short)
        expectFailure("routing_candidate_budget_exhausted") {
            try graph.addUndirected(from: node(0, 0), to: node(1, 0), contact: nil, budget: &short)
        }
        var inspection = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try graph.firstEdge(from: node(0, 0), budget: &inspection) == nil)
        #expect(try graph.firstEdge(from: node(1, 0), budget: &inspection) == nil)
    }

    @Test func cancelledTraversalCannotReturnPartialDistances() async throws {
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var graph = try PhysicalDesignRoutingEventGraph(xCount: 2, yCount: 1, layers: [2], defaultMasterCount: 0, budget: &budget)
        try graph.addUndirected(from: node(0, 0), to: node(1, 0), contact: nil, budget: &budget)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var cancelled = PhysicalDesignRoutingWorkBudget(caller: nil)
            return try graph.reverseDistances(targets: [.init(x: 1, y: 0, layer: 2)], budget: &cancelled)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func exercise(caller: Int?) throws -> (checks: Int, capacity: Int) {
        var budget = PhysicalDesignRoutingWorkBudget(caller: caller)
        var graph = try PhysicalDesignRoutingEventGraph(xCount: 3, yCount: 1, layers: [2], defaultMasterCount: 0, budget: &budget)
        try graph.addUndirected(from: node(0, 0), to: node(1, 0), contact: nil, budget: &budget)
        try graph.addUndirected(from: node(1, 0), to: node(2, 0), contact: nil, budget: &budget)
        #expect(try graph.reverseDistances(targets: [node(2, 0)], budget: &budget) == [2, 1, 0])
        return (budget.checks, budget.capacity)
    }

    private func node(_ x: Int, _ y: Int, layer: Int = 2) -> Node { .init(x: x, y: y, layer: layer) }

    private func expectFailure(_ code: String, _ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("An invalid or unadmitted graph operation succeeded")
        } catch let error as PhysicalDesignSourceRouter.Failure {
            #expect(error.code == code)
        } catch { Issue.record(error) }
    }
}
