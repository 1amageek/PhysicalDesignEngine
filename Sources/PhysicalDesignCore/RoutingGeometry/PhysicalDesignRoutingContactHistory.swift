import LayoutIR

/// Net-local ownership of translated contacts and canonical persistent contact sets.
struct PhysicalDesignRoutingContactHistory {
    private struct ContactKey: Hashable {
        let net: String
        let master: String?
        let x: Int64
        let y: Int64
        let lower: Int
        let upper: Int
        init(_ via: PhysicalDesignSnapshot.Via) {
            net = via.netID; master = via.master; x = via.x; y = via.y
            lower = via.lowerLayer; upper = via.upperLayer
        }
    }
    struct Contact {
        let via: PhysicalDesignSnapshot.Via
        let shapes: [IRBoundary]
    }
    private struct History {
        let parent: Int
        let contact: Int
        let count: Int
        let fingerprint: UInt64
    }
    private struct Bucket: Hashable {
        let count: Int
        let fingerprint: UInt64
    }
    let maximumContacts: Int
    let maximumHistories: Int
    private(set) var contacts: [Contact] = []
    private var contactIndices: [ContactKey: Int] = [:]
    // History zero is the empty set. Every other record shares an immutable prefix.
    private var histories: [History] = [.init(parent: 0, contact: -1, count: 0, fingerprint: 0)]
    private var buckets: [Bucket: [Int]] = [:]

    init(maximumContacts: Int, maximumHistories: Int) {
        self.maximumContacts = maximumContacts
        self.maximumHistories = maximumHistories
    }

    mutating func retain(_ via: PhysicalDesignSnapshot.Via, shapes: [IRBoundary],
                         budget: inout PhysicalDesignRoutingWorkBudget) throws -> Int {
        let key = ContactKey(via)
        try Self.charge(1, budget: &budget)
        if let index = contactIndices[key] { return index }
        guard contacts.count < maximumContacts else { throw Self.exhausted() }
        var cost = 2
        for shape in shapes {
            cost = try Self.add(cost, try Self.add(1, shape.points.count))
        }
        try Self.charge(cost, budget: &budget)
        let index = contacts.count
        // COW retains the selector's already translated buffer; no historical reprojection.
        contacts.append(.init(via: via, shapes: shapes))
        contactIndices[key] = index
        return index
    }

    func contains(_ contact: Int, in history: Int,
                  budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        var cursor = history
        while cursor != 0 {
            try Self.charge(1, budget: &budget)
            if histories[cursor].contact == contact { return true }
            cursor = histories[cursor].parent
        }
        return false
    }

    func isSubset(_ first: Int, of second: Int,
                  budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        try Self.charge(1, budget: &budget)
        if first == second { return true }
        guard histories[first].count <= histories[second].count else { return false }
        var cursor = first
        while cursor != 0 {
            if try !contains(histories[cursor].contact, in: second, budget: &budget) { return false }
            cursor = histories[cursor].parent
        }
        return true
    }

    mutating func adding(_ contact: Int?, to history: Int,
                         budget: inout PhysicalDesignRoutingWorkBudget) throws -> Int {
        guard let contact else { return history }
        guard try !contains(contact, in: history, budget: &budget) else { return history }
        let count = try Self.add(histories[history].count, 1)
        let fingerprint = histories[history].fingerprint ^ UInt64(contact + 1)
        let key = Bucket(count: count, fingerprint: fingerprint)
        // Fingerprints locate candidates only. Exact set membership decides identity.
        if let candidates = buckets[key] {
            for candidate in candidates {
                try Self.charge(1, budget: &budget)
                guard try contains(contact, in: candidate, budget: &budget) else { continue }
                var cursor = history, equal = true
                while cursor != 0 {
                    if try !contains(histories[cursor].contact, in: candidate, budget: &budget) {
                        equal = false; break
                    }
                    cursor = histories[cursor].parent
                }
                if equal { return candidate }
            }
        }
        guard histories.count - 1 < maximumHistories else { throw Self.exhausted() }
        try Self.charge(3, budget: &budget)
        let index = histories.count
        histories.append(.init(parent: history, contact: contact, count: count, fingerprint: fingerprint))
        buckets[key, default: []].append(index)
        return index
    }

    func fits(_ contact: Int?, history: Int, geometry: PhysicalDesignProcessGeometry,
              budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        guard let contact else { return true }
        let candidate = contacts[contact]
        return try fits(candidate.via, shapes: candidate.shapes, history: history,
                        geometry: geometry, budget: &budget)
    }

    func fits(_ via: PhysicalDesignSnapshot.Via, shapes: borrowing [IRBoundary], history: Int,
              geometry: PhysicalDesignProcessGeometry,
              budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        var cursor = history
        while cursor != 0 {
            try Self.charge(1, budget: &budget)
            let other = contacts[histories[cursor].contact]
            if try !geometry.routingCutPairFits(via, shapes: shapes, against: other.via,
                                               otherShapes: other.shapes, budget: &budget) { return false }
            cursor = histories[cursor].parent
        }
        return true
    }

    func forEachContact(in history: Int, budget: inout PhysicalDesignRoutingWorkBudget,
                        _ body: (Int, PhysicalDesignSnapshot.Via) throws -> Void) throws {
        var cursor = history
        while cursor != 0 {
            try Self.charge(1, budget: &budget)
            let index = histories[cursor].contact
            try body(index, contacts[index].via)
            cursor = histories[cursor].parent
        }
    }

    private static func charge(_ count: Int, budget: inout PhysicalDesignRoutingWorkBudget) throws {
        try budget.extend(count); try budget.charge(count)
    }
    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let sum = a.addingReportingOverflow(b)
        guard !sum.overflow else { throw exhausted() }
        return sum.partialValue
    }
    private static func exhausted() -> PhysicalDesignSourceRouter.Failure {
        .init(code: "routing_candidate_budget_exhausted", message: "The finite contact/history arena allowance was exhausted.")
    }
}
