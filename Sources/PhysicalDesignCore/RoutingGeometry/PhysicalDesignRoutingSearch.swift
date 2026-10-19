/// Dense predecessor arena and deterministic goal-directed frontier; labels never own copied paths.
struct PhysicalDesignRoutingSearch {
    struct Node: Hashable {
        let x: Int
        let y: Int
        let layer: Int
    }
    struct Label {
        let node: Node
        let rootAccess: Int
        let history: Int
        let previous: Int?
        let contact: Int?
        let distance: Int
        let remaining: Int
        let priority: Int
        let nextAtNode: Int?
    }
    let maximumLabels: Int
    private(set) var labels: [Label] = []
    private var nodeHeads: [Node: Int] = [:]
    private var active: [Bool] = []
    private var frontier: [Int] = []

    init(maximumLabels: Int) { self.maximumLabels = maximumLabels }

    func contains(node: Node, history: Int, distance: Int, hasPredecessor: Bool,
                  budget: inout PhysicalDesignRoutingWorkBudget,
                  isSubset: (Int, Int, inout PhysicalDesignRoutingWorkBudget) throws -> Bool = { a, b, _ in a == b }) throws -> Bool {
        try Self.charge(1, budget: &budget)
        var cursor = nodeHeads[node]
        while let index = cursor {
            try Self.charge(1, budget: &budget)
            let label = labels[index]
            if active[index], label.distance <= distance, label.previous != nil || !hasPredecessor,
               try isSubset(label.history, history, &budget) { return true }
            cursor = label.nextAtNode
        }
        return false
    }

    mutating func append(node: Node, rootAccess: Int, history: Int, previous: Int?, contact: Int?,
                         remaining: Int = 0, budget: inout PhysicalDesignRoutingWorkBudget,
                         isSubset: (Int, Int, inout PhysicalDesignRoutingWorkBudget) throws -> Bool = { a, b, _ in a == b }) throws {
        let distance = try previous.map { try Self.add(labels[$0].distance, 1) } ?? 0
        guard remaining >= 0 else { throw Self.overflow() }
        let priority = try Self.add(distance, remaining)
        guard try !contains(node: node, history: history, distance: distance, hasPredecessor: previous != nil,
            budget: &budget, isSubset: isSubset) else { return }
        guard labels.count < maximumLabels else {
            throw PhysicalDesignSourceRouter.Failure(code: "routing_candidate_budget_exhausted",
                message: try exhaustionMessage(budget: &budget))
        }
        try Self.charge(4, budget: &budget)
        let index = labels.count, priorHead = nodeHeads[node]
        labels.append(.init(node: node, rootAccess: rootAccess, history: history, previous: previous,
            contact: contact, distance: distance, remaining: remaining, priority: priority, nextAtNode: priorHead))
        active.append(true)
        nodeHeads[node] = index
        frontier.append(index)
        var cursor = priorHead
        while let prior = cursor {
            try Self.charge(1, budget: &budget)
            let label = labels[prior]
            if active[prior], distance <= label.distance, previous != nil || label.previous == nil,
               try isSubset(history, label.history, &budget) {
                try Self.charge(1, budget: &budget)
                active[prior] = false
            }
            cursor = label.nextAtNode
        }
        var child = frontier.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            try Self.charge(1, budget: &budget)
            guard precedes(frontier[child], frontier[parent]) else { break }
            try Self.charge(1, budget: &budget)
            frontier.swapAt(child, parent)
            child = parent
        }
    }

    mutating func next(budget: inout PhysicalDesignRoutingWorkBudget) throws -> Int? {
        while let first = frontier.first {
            try Self.charge(1, budget: &budget)
            let last = frontier.removeLast()
            if !frontier.isEmpty {
                try Self.charge(1, budget: &budget)
                frontier[0] = last
                var parent = 0
                // Internal nodes alone have children, avoiding multiplication beyond the admitted index range.
                while parent < frontier.count / 2 {
                    let left = parent * 2 + 1, right = left + 1
                    var child = left
                    if right < frontier.count {
                        try Self.charge(1, budget: &budget)
                        if precedes(frontier[right], frontier[left]) { child = right }
                    }
                    try Self.charge(1, budget: &budget)
                    guard precedes(frontier[child], frontier[parent]) else { break }
                    try Self.charge(1, budget: &budget)
                    frontier.swapAt(child, parent)
                    parent = child
                }
            }
            if active[first] { return first }
        }
        return nil
    }

    private func exhaustionMessage(budget: inout PhysicalDesignRoutingWorkBudget) throws -> String {
        let original = "The finite search-label arena allowance was exhausted."
        try Task.checkCancellation()
        let bucketsAndLabels = nodeHeads.count.addingReportingOverflow(labels.count)
        let scanWork = bucketsAndLabels.partialValue.addingReportingOverflow(frontier.count)
        let capacity = budget.capacity.addingReportingOverflow(scanWork.partialValue)
        guard !bucketsAndLabels.overflow, !scanWork.overflow, !capacity.overflow else {
            return original + " observation=unavailable-budget-capacity"
        }
        if let caller = budget.caller, scanWork.partialValue > caller - budget.checks {
            return original + " observation=unavailable-caller-budget"
        }
        try budget.extend(scanWork.partialValue); try budget.charge(scanWork.partialValue)
        var activeCount = 0, maxBucket = 0, maxActiveBucket = 0
        for head in nodeHeads.values {
            var cursor: Int? = head, bucketCount = 0, activeBucketCount = 0
            while let index = cursor {
                try Task.checkCancellation()
                bucketCount += 1
                if active[index] { activeCount += 1; activeBucketCount += 1 }
                cursor = labels[index].nextAtNode
            }
            maxBucket = max(maxBucket, bucketCount)
            maxActiveBucket = max(maxActiveBucket, activeBucketCount)
        }
        var openActive = 0, minG = Int.max, maxG = -1, minH = Int.max, maxH = -1
        for index in frontier where active[index] {
            openActive += 1
            minG = min(minG, labels[index].distance); maxG = max(maxG, labels[index].distance)
            minH = min(minH, labels[index].remaining); maxH = max(maxH, labels[index].remaining)
        }
        try Task.checkCancellation()
        if openActive == 0 { minG = -1; minH = -1 }
        let message = original + " labels=\(labels.count) active=\(activeCount) retired=\(labels.count - activeCount)"
            + " frontier=\(frontier.count) openActive=\(openActive) openRetired=\(frontier.count - openActive)"
            + " nodes=\(nodeHeads.count) maxBucket=\(maxBucket) maxActiveBucket=\(maxActiveBucket)"
            + " minG=\(minG) maxG=\(maxG) minH=\(minH) maxH=\(maxH)"
        // Thirteen fixed keys and signed Int scalars use at most 420 UTF-8 bytes on 64-bit targets.
        return message
    }

    private func precedes(_ first: Int, _ second: Int) -> Bool {
        let a = labels[first], b = labels[second]
        if a.priority != b.priority { return a.priority < b.priority }
        if a.remaining != b.remaining { return a.remaining < b.remaining }
        return first < second
    }
    private static func charge(_ amount: Int, budget: inout PhysicalDesignRoutingWorkBudget) throws {
        try budget.extend(amount); try budget.charge(amount)
    }
    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let sum = a.addingReportingOverflow(b)
        guard !sum.overflow else { throw overflow() }
        return sum.partialValue
    }
    private static func overflow() -> PhysicalDesignSourceRouter.Failure {
        .init(code: "routing_coordinate_overflow", message: "Search priority exceeds the index range.")
    }
}
