import Foundation

/// One exclusively owned admission counter shared by geometry and route search.
struct PhysicalDesignRoutingWorkBudget: ~Copyable {
    private(set) var checks = 0
    private(set) var capacity = 0
    let caller: Int?
    var remaining: Int { min(capacity, caller ?? capacity) - checks }
    mutating func admit() throws { try charge(1) }
    mutating func charge(_ amount: Int) throws {
        try Task.checkCancellation()
        guard amount >= 0, amount <= remaining else {
            throw PhysicalDesignSourceRouter.Failure(code: "routing_candidate_budget_exhausted", message: "The admitted geometry/search ceiling was exhausted.")
        }
        checks += amount
    }
    mutating func extend(_ amount: Int) throws {
        let (next, overflow) = capacity.addingReportingOverflow(amount)
        guard amount >= 0, !overflow else {
            throw PhysicalDesignSourceRouter.Failure(code: "routing_coordinate_overflow", message: "Routing work exceeds the index range.")
        }
        capacity = next
    }
    mutating func admitSort(_ count: Int) throws {
        var levels = 0, size = count
        while size > 1 { levels += 1; size = size / 2 + size % 2 }
        let (cost, overflow) = count.multipliedReportingOverflow(by: 2 * max(1, levels))
        guard count >= 0, !overflow else {
            throw PhysicalDesignSourceRouter.Failure(code: "routing_coordinate_overflow", message: "Sort work exceeds the index range.")
        }
        try extend(cost); try charge(cost)
    }
}
