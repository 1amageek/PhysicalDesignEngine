/// Invocation-local static edges supplied by the source-geometry owner.
/// The graph preserves parallel contact identities and insertion order; it does not qualify geometry.
struct PhysicalDesignRoutingEventGraph {
    typealias Node = PhysicalDesignRoutingSearch.Node

    struct Edge {
        let destination: Node
        let contact: Int?
        fileprivate(set) var next: Int?
    }

    private let xCount: Int
    private let yCount: Int
    private let nodeCount: Int
    private let maximumEdges: Int
    private let layerOrdinals: [Int: Int]
    private var heads: [Int?]
    private var tails: [Int?]
    private var edges: [Edge] = []

    init(xCount: Int, yCount: Int, layers: [Int], defaultMasterCount: Int, terminalAccessCount: Int = 0,
         budget: inout PhysicalDesignRoutingWorkBudget) throws {
        guard xCount > 0, yCount > 0, !layers.isEmpty, defaultMasterCount >= 0, terminalAccessCount >= 0 else {
            throw Self.invalid()
        }
        let xy = try Self.multiply(xCount, yCount)
        let nodes = try Self.multiply(layers.count, xy)
        let ordinaryEdges = try Self.add(Self.multiply(2, nodes), Self.multiply(2, Self.multiply(xy, defaultMasterCount)))
        let edgeLimit = try Self.add(ordinaryEdges, Self.multiply(4, terminalAccessCount))
        let headTailCount = try Self.multiply(2, nodes)
        let storage = try Self.add(Self.add(headTailCount, edgeLimit), layers.count)
        // Entry and byte arithmetic must both fit before any dense storage is allocated.
        _ = try Self.add(Self.multiply(headTailCount, MemoryLayout<Int?>.stride),
                         Self.add(Self.multiply(edgeLimit, MemoryLayout<Edge>.stride),
                                  Self.multiply(layers.count, 2 * MemoryLayout<Int>.stride)))
        try Self.charge(storage, budget: &budget)
        var ordinals: [Int: Int] = [:]
        ordinals.reserveCapacity(layers.count)
        for (ordinal, layer) in layers.enumerated() {
            try Self.charge(1, budget: &budget)
            guard ordinals.updateValue(ordinal, forKey: layer) == nil else { throw Self.invalid() }
        }
        self.xCount = xCount
        self.yCount = yCount
        nodeCount = nodes
        maximumEdges = edgeLimit
        layerOrdinals = ordinals
        heads = Array(repeating: nil, count: nodes)
        tails = Array(repeating: nil, count: nodes)
        edges.reserveCapacity(edgeLimit)
    }

    /// The caller charges direct index queries; other graph entry points charge their own queries.
    func index(of node: Node) throws -> Int {
        guard node.x >= 0, node.x < xCount, node.y >= 0, node.y < yCount,
              let ordinal = layerOrdinals[node.layer] else { throw Self.invalid() }
        // Domain admission proves every intermediate is below the checked nodeCount.
        return (ordinal * xCount + node.x) * yCount + node.y
    }

    mutating func addUndirected(from: Node, to: Node, contact: Int?,
                                budget: inout PhysicalDesignRoutingWorkBudget) throws {
        try Self.charge(2, budget: &budget)
        let first = try index(of: from), second = try index(of: to)
        guard first != second, contact.map({ $0 >= 0 }) ?? true else { throw Self.invalid() }
        guard edges.count <= maximumEdges - 2 else {
            throw PhysicalDesignSourceRouter.Failure(code: "routing_candidate_budget_exhausted",
                message: "The finite static event-edge allowance was exhausted.")
        }
        // Admit both edges and both head/tail updates before changing either adjacency chain.
        try Self.charge(6, budget: &budget)
        append(from: first, destination: to, contact: contact)
        append(from: second, destination: from, contact: contact)
    }

    func firstEdge(from node: Node, budget: inout PhysicalDesignRoutingWorkBudget) throws -> Int? {
        try Self.charge(1, budget: &budget)
        return heads[try index(of: node)]
    }

    func edge(at index: Int, budget: inout PhysicalDesignRoutingWorkBudget) throws -> Edge {
        try Self.charge(1, budget: &budget)
        guard edges.indices.contains(index) else { throw Self.invalid() }
        return edges[index]
    }

    /// Distances in the caller-supplied undirected supergraph; -1 means unreachable, not zero.
    func reverseDistances(targets: [Node], budget: inout PhysicalDesignRoutingWorkBudget) throws -> [Int] {
        try Self.charge(Self.multiply(2, nodeCount), budget: &budget)
        var distances = Array(repeating: -1, count: nodeCount)
        var queue = Array(repeating: 0, count: nodeCount)
        var read = 0, write = 0
        for target in targets {
            try Self.charge(1, budget: &budget)
            let index = try index(of: target)
            if distances[index] < 0 {
                guard write < nodeCount else { throw Self.invalid() }
                try Self.charge(2, budget: &budget)
                distances[index] = 0
                queue[write] = index
                write += 1
            }
        }
        while read < write {
            try Self.charge(1, budget: &budget)
            let current = queue[read]
            read += 1
            var cursor = heads[current]
            while let edgeIndex = cursor {
                try Self.charge(2, budget: &budget)
                let edge = edges[edgeIndex]
                let destination = try index(of: edge.destination)
                if distances[destination] < 0 {
                    let nextDistance = try Self.add(distances[current], 1)
                    guard write < nodeCount else { throw Self.invalid() }
                    try Self.charge(2, budget: &budget)
                    distances[destination] = nextDistance
                    queue[write] = destination
                    write += 1
                }
                cursor = edge.next
            }
        }
        return distances
    }

    private mutating func append(from source: Int, destination: Node, contact: Int?) {
        let index = edges.count
        edges.append(.init(destination: destination, contact: contact, next: nil))
        if let tail = tails[source] { edges[tail].next = index }
        else { heads[source] = index }
        tails[source] = index
    }

    private static func charge(_ amount: Int, budget: inout PhysicalDesignRoutingWorkBudget) throws {
        try budget.extend(amount)
        try budget.charge(amount)
    }

    private static func add(_ first: Int, _ second: Int) throws -> Int {
        let (value, overflow) = first.addingReportingOverflow(second)
        guard !overflow, value >= 0 else { throw invalid() }
        return value
    }

    private static func multiply(_ first: Int, _ second: Int) throws -> Int {
        let (value, overflow) = first.multipliedReportingOverflow(by: second)
        guard !overflow, value >= 0 else { throw invalid() }
        return value
    }

    private static func invalid() -> PhysicalDesignSourceRouter.Failure {
        .init(code: "routing_coordinate_overflow", message: "Static event graph dimensions, capacity or index are invalid.")
    }
}
