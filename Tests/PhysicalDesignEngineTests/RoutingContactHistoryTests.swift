import Foundation
import PDKCore
import Testing
@testable import PhysicalDesignCore

@Suite("Canonical finite routing contact histories", .timeLimit(.minutes(1)))
struct RoutingContactHistoryTests {
    @Test("contact sets ignore insertion order and physical reuse loops")
    func canonicalSets() async throws {
        let geometry = try await fixture()
        var arena = PhysicalDesignRoutingContactHistory(maximumContacts: 3, maximumHistories: 8)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let first = contact("first", x: 1000), second = contact("second", x: 2000)
        let a = try arena.retain(first, shapes: geometry.viaShapes(master: "hv", x: 1000, y: 1000), budget: &budget)
        let b = try arena.retain(second, shapes: geometry.viaShapes(master: "hv", x: 2000, y: 1000), budget: &budget)
        var reused = first; reused.id = "another-record"; reused.isRedundant = true
        let again = try arena.retain(reused, shapes: geometry.viaShapes(master: "hv", x: 1000, y: 1000), budget: &budget)
        #expect(a == again && arena.contacts.count == 2)
        var otherMaster = first; otherMaster.master = "alias"
        let alternate = try arena.retain(otherMaster, shapes: geometry.viaShapes(master: "alias", x: 1000, y: 1000), budget: &budget)
        #expect(alternate != a && arena.contacts.count == 3)
        let onlyA = try arena.adding(a, to: 0, budget: &budget)
        let onlyB = try arena.adding(b, to: 0, budget: &budget)
        let ab = try arena.adding(b, to: onlyA, budget: &budget)
        let ba = try arena.adding(a, to: onlyB, budget: &budget)
        #expect(ab == ba)
        #expect(try arena.adding(a, to: ab, budget: &budget) == ab)
        #expect(try arena.adding(nil, to: ab, budget: &budget) == ab)
        let different = try arena.adding(alternate, to: onlyB, budget: &budget)
        #expect(different != ab)
        #expect(try arena.isSubset(0, of: ab, budget: &budget))
        #expect(try arena.isSubset(onlyA, of: ab, budget: &budget))
        #expect(try arena.isSubset(ab, of: ba, budget: &budget))
        #expect(try !arena.isSubset(ab, of: onlyA, budget: &budget))
        #expect(try !arena.isSubset(different, of: ab, budget: &budget))
        var visited: [Int] = []
        try arena.forEachContact(in: ab, budget: &budget) { index, _ in visited.append(index) }
        #expect(visited.count == 2 && Set(visited) == Set([a, b]))
    }

    @Test("equal contact fingerprints never substitute for exact set membership")
    func fingerprintCollision() async throws {
        let geometry = try await fixture()
        var arena = PhysicalDesignRoutingContactHistory(maximumContacts: 7, maximumHistories: 8)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var contacts: [Int] = []
        for index in 0..<7 {
            let via = contact("contact-\(index)", x: 1000 + Int64(index * 500))
            contacts.append(try arena.retain(via, shapes: geometry.viaShapes(master: "hv", x: via.x, y: via.y), budget: &budget))
        }
        // Equal count and (1 XOR 2) == (4 XOR 7) must still identify distinct sets.
        let leftParent = try arena.adding(contacts[0], to: 0, budget: &budget)
        let left = try arena.adding(contacts[1], to: leftParent, budget: &budget)
        let rightParent = try arena.adding(contacts[3], to: 0, budget: &budget)
        let right = try arena.adding(contacts[6], to: rightParent, budget: &budget)
        #expect(left != right)
        #expect(try arena.contains(contacts[0], in: left, budget: &budget))
        #expect(try !arena.contains(contacts[0], in: right, budget: &budget))
        #expect(try !arena.isSubset(left, of: right, budget: &budget))
        #expect(try !arena.isSubset(right, of: left, budget: &budget))
    }

    @Test("equal histories merge across root accesses while different histories remain")
    func labelIdentity() throws {
        var search = PhysicalDesignRoutingSearch(maximumLabels: 3)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let node = PhysicalDesignRoutingSearch.Node(x: 1, y: 2, layer: 3)
        try search.append(node: node, rootAccess: 0, history: 1, previous: nil, contact: nil, budget: &budget)
        try search.append(node: node, rootAccess: 0, history: 2, previous: 0, contact: 7, budget: &budget)
        try search.append(node: node, rootAccess: 1, history: 1, previous: nil, contact: 8, budget: &budget)
        try search.append(node: node, rootAccess: 9, history: 2, previous: 0, contact: 9, budget: &budget)
        #expect(search.labels.count == 2)
        #expect(search.labels[0].previous == nil && search.labels[1].previous == 0 && search.labels[1].contact == 7)
        #expect(search.labels[0].history != search.labels[1].history && search.labels[0].rootAccess == 0)
        #expect(try search.next(budget: &budget) == 0)
        #expect(try search.next(budget: &budget) == 1)
        #expect(try search.next(budget: &budget) == nil)
    }

    @Test("a 170 DBU cut at 340 center separation fails 190 spacing while another history remains legal")
    func targetHistoryLegality() async throws {
        let geometry = try await fixture()
        var arena = PhysicalDesignRoutingContactHistory(maximumContacts: 3, maximumHistories: 4)
        var search = PhysicalDesignRoutingSearch(maximumLabels: 2)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let target = contact("target", x: 2000), bad = contact("bad", x: 1660), good = contact("good", x: 1640)
        let targetID = try arena.retain(target, shapes: geometry.viaShapes(master: "hv", x: target.x, y: target.y), budget: &budget)
        let badID = try arena.retain(bad, shapes: geometry.viaShapes(master: "hv", x: bad.x, y: bad.y), budget: &budget)
        let goodID = try arena.retain(good, shapes: geometry.viaShapes(master: "hv", x: good.x, y: good.y), budget: &budget)
        let badHistory = try arena.adding(badID, to: 0, budget: &budget)
        let goodHistory = try arena.adding(goodID, to: 0, budget: &budget)
        let node = PhysicalDesignRoutingSearch.Node(x: 2, y: 1, layer: 3)
        try search.append(node: node, rootAccess: 0, history: badHistory, previous: nil, contact: badID, budget: &budget)
        try search.append(node: node, rootAccess: 0, history: goodHistory, previous: nil, contact: goodID, budget: &budget)
        let first = try #require(try search.next(budget: &budget))
        #expect(try !arena.fits(targetID, history: search.labels[first].history, geometry: geometry, budget: &budget))
        let second = try #require(try search.next(budget: &budget))
        #expect(try arena.fits(targetID, history: search.labels[second].history, geometry: geometry, budget: &budget))
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.validateRoutingCuts([bad, target]) }
        try geometry.validateRoutingCuts([good, target])
    }

    @Test("contact history and label arenas each enforce their own finite cap", arguments: ["contacts", "histories", "labels"])
    func finiteAdmission(_ resource: String) async throws {
        let geometry = try await fixture(), first = contact("first", x: 1000), second = contact("second", x: 2000)
        let a = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        let b = try geometry.viaShapes(master: "hv", x: second.x, y: second.y)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        var arena = PhysicalDesignRoutingContactHistory(maximumContacts: resource == "contacts" ? 1 : 2, maximumHistories: 1)
        let one = try arena.retain(first, shapes: a, budget: &budget)
        if resource == "contacts" {
            #expect(try arena.retain(first, shapes: a, budget: &budget) == one)
            #expect(throws: PhysicalDesignSourceRouter.Failure.self) { try arena.retain(second, shapes: b, budget: &budget) }
            #expect(arena.contacts.count == 1)
        } else if resource == "histories" {
            let two = try arena.retain(second, shapes: b, budget: &budget)
            let history = try arena.adding(one, to: 0, budget: &budget)
            #expect(try arena.adding(one, to: history, budget: &budget) == history)
            #expect(throws: PhysicalDesignSourceRouter.Failure.self) { try arena.adding(two, to: history, budget: &budget) }
        } else {
            var search = PhysicalDesignRoutingSearch(maximumLabels: 1)
            let node = PhysicalDesignRoutingSearch.Node(x: 0, y: 0, layer: 2)
            try search.append(node: node, rootAccess: 0, history: 0, previous: nil, contact: nil, budget: &budget)
            try search.append(node: node, rootAccess: 0, history: 0, previous: nil, contact: nil, budget: &budget)
            #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
                try search.append(node: .init(x: 1, y: 0, layer: 2), rootAccess: 1, history: 0, previous: nil, contact: nil, budget: &budget)
            }
            #expect(search.labels.count == 1)
        }
    }

    @Test("all history and label work shares the caller allowance", arguments: ["retain", "adding", "fits", "enumerate", "subset", "label"])
    func callerQuota(_ operation: String) async throws {
        let geometry = try await fixture(), first = contact("first", x: 1000)
        let shapes = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        var arena = PhysicalDesignRoutingContactHistory(maximumContacts: 2, maximumHistories: 2)
        var setup = PhysicalDesignRoutingWorkBudget(caller: nil)
        let one = try arena.retain(first, shapes: shapes, budget: &setup)
        let history = try arena.adding(one, to: 0, budget: &setup)
        var limited = PhysicalDesignRoutingWorkBudget(caller: operation == "enumerate" || operation == "subset" ? 0 : 1)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            switch operation {
            case "retain":
                let second = contact("second", x: 2000)
                _ = try arena.retain(second, shapes: geometry.viaShapes(master: "hv", x: second.x, y: second.y), budget: &limited)
            case "adding": _ = try arena.adding(one, to: 0, budget: &limited)
            case "fits": _ = try arena.fits(one, history: history, geometry: geometry, budget: &limited)
            case "enumerate": try arena.forEachContact(in: history, budget: &limited) { _, _ in Issue.record("Quota must precede callback.") }
            case "subset": _ = try arena.isSubset(history, of: history, budget: &limited)
            default:
                var search = PhysicalDesignRoutingSearch(maximumLabels: 1)
                try search.append(node: .init(x: 0, y: 0, layer: 2), rootAccess: 0, history: 0, previous: nil, contact: nil, budget: &limited)
            }
        }
        #expect(limited.checks <= (limited.caller ?? 0))
        #expect(try arena.contains(one, in: history, budget: &setup))
    }

    @Test("cancelled contact and label operations preserve cancellation", arguments: ["retain", "adding", "fits", "enumerate", "subset", "label"])
    func cancellation(_ operation: String) async throws {
        let geometry = try await fixture(), first = contact("first", x: 1000)
        let shapes = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        var prepared = PhysicalDesignRoutingContactHistory(maximumContacts: 2, maximumHistories: 2)
        var setup = PhysicalDesignRoutingWorkBudget(caller: nil)
        let one = try prepared.retain(first, shapes: shapes, budget: &setup)
        let history = try prepared.adding(one, to: 0, budget: &setup)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var arena = prepared, budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            do {
                switch operation {
                case "retain": _ = try arena.retain(first, shapes: shapes, budget: &budget)
                case "adding": _ = try arena.adding(one, to: history, budget: &budget)
                case "fits": _ = try arena.fits(one, history: history, geometry: geometry, budget: &budget)
                case "enumerate": try arena.forEachContact(in: history, budget: &budget) { _, _ in Issue.record("Cancellation must precede callback.") }
                case "subset": _ = try arena.isSubset(history, of: history, budget: &budget)
                default:
                    var search = PhysicalDesignRoutingSearch(maximumLabels: 1)
                    try search.append(node: .init(x: 0, y: 0, layer: 2), rootAccess: 0, history: 0, previous: nil, contact: nil, budget: &budget)
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        #expect(await task.value)
    }

    @Test("a cheaper subset retires a label without losing either predecessor path")
    func dominanceAndReconstruction() async throws {
        let geometry = try await fixture()
        var arena = PhysicalDesignRoutingContactHistory(maximumContacts: 2, maximumHistories: 3)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let a = try arena.retain(contact("A", x: 1000), shapes: geometry.viaShapes(master: "hv", x: 1000, y: 1000), budget: &budget)
        let b = try arena.retain(contact("B", x: 2000), shapes: geometry.viaShapes(master: "hv", x: 2000, y: 1000), budget: &budget)
        let onlyA = try arena.adding(a, to: 0, budget: &budget)
        let ab = try arena.adding(b, to: onlyA, budget: &budget)
        let subset: (Int, Int, inout PhysicalDesignRoutingWorkBudget) throws -> Bool = { first, second, work in
            try arena.isSubset(first, of: second, budget: &work)
        }
        var search = PhysicalDesignRoutingSearch(maximumLabels: 6)
        let meet = PhysicalDesignRoutingSearch.Node(x: 2, y: 0, layer: 2)
        try search.append(node: .init(x: 0, y: 0, layer: 2), rootAccess: 0, history: ab, previous: nil, contact: nil, budget: &budget, isSubset: subset)
        try search.append(node: .init(x: 1, y: 0, layer: 2), rootAccess: 0, history: ab, previous: 0, contact: nil, budget: &budget, isSubset: subset)
        try search.append(node: meet, rootAccess: 0, history: ab, previous: 1, contact: b, budget: &budget, isSubset: subset)
        try search.append(node: .init(x: 3, y: 0, layer: 2), rootAccess: 0, history: ab, previous: 2, contact: nil, budget: &budget, isSubset: subset)
        try search.append(node: .init(x: 2, y: 1, layer: 2), rootAccess: 1, history: onlyA, previous: nil, contact: a, budget: &budget, isSubset: subset)
        try search.append(node: meet, rootAccess: 1, history: onlyA, previous: 4, contact: nil, budget: &budget, isSubset: subset)
        #expect(search.labels.count == 6 && search.labels[5].distance == 1 && search.labels[2].distance == 2)
        // At the hard cap, dominated candidates are discarded before arena growth.
        try search.append(node: meet, rootAccess: 9, history: ab, previous: 3, contact: b, budget: &budget, isSubset: subset)
        try search.append(node: meet, rootAccess: 8, history: onlyA, previous: 4, contact: nil, budget: &budget, isSubset: subset)
        #expect(search.labels.count == 6 && search.labels[5].rootAccess == 1)
        #expect(try search.contains(node: meet, history: ab, distance: 2, hasPredecessor: true, budget: &budget, isSubset: subset))
        var winningPath: [Int] = [], cursor: Int? = 5
        while let index = cursor { winningPath.append(index); cursor = search.labels[index].previous }
        #expect(winningPath == [5, 4])
        var retainedPath: [Int] = []; cursor = 3
        while let index = cursor { retainedPath.append(index); cursor = search.labels[index].previous }
        #expect(retainedPath == [3, 2, 1, 0])
        var popped: [Int] = []
        while let index = try search.next(budget: &budget) { popped.append(index) }
        #expect(popped.count == 5 && Set(popped) == Set([0, 1, 3, 4, 5]))
    }

    @Test("incomparable master contact sets remain separate future states")
    func incomparableMasterHistories() async throws {
        let geometry = try await fixture()
        var arena = PhysicalDesignRoutingContactHistory(maximumContacts: 2, maximumHistories: 2)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let original = contact("A", x: 1000)
        var alternate = original; alternate.master = "alias"
        let a = try arena.retain(original, shapes: geometry.viaShapes(master: "hv", x: 1000, y: 1000), budget: &budget)
        let b = try arena.retain(alternate, shapes: geometry.viaShapes(master: "alias", x: 1000, y: 1000), budget: &budget)
        let first = try arena.adding(a, to: 0, budget: &budget)
        let second = try arena.adding(b, to: 0, budget: &budget)
        #expect(try !arena.isSubset(first, of: second, budget: &budget))
        #expect(try !arena.isSubset(second, of: first, budget: &budget))
        var search = PhysicalDesignRoutingSearch(maximumLabels: 2)
        let node = PhysicalDesignRoutingSearch.Node(x: 0, y: 0, layer: 2)
        try search.append(node: node, rootAccess: 0, history: first, previous: nil, contact: a, budget: &budget) { lhs, rhs, work in
            try arena.isSubset(lhs, of: rhs, budget: &work)
        }
        try search.append(node: node, rootAccess: 1, history: second, previous: nil, contact: b, budget: &budget) { lhs, rhs, work in
            try arena.isSubset(lhs, of: rhs, budget: &work)
        }
        #expect(search.labels.count == 2)
        #expect(try search.next(budget: &budget) == 0)
        #expect(try search.next(budget: &budget) == 1)
    }

    @Test("a smaller contact set with a longer path does not dominate a cheaper superset")
    func distanceSubsetTradeoff() async throws {
        let geometry = try await fixture()
        var arena = PhysicalDesignRoutingContactHistory(maximumContacts: 2, maximumHistories: 3)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let a = try arena.retain(contact("A", x: 1000), shapes: geometry.viaShapes(master: "hv", x: 1000, y: 1000), budget: &budget)
        let b = try arena.retain(contact("B", x: 2000), shapes: geometry.viaShapes(master: "hv", x: 2000, y: 1000), budget: &budget)
        let onlyA = try arena.adding(a, to: 0, budget: &budget)
        let ab = try arena.adding(b, to: onlyA, budget: &budget)
        let subset: (Int, Int, inout PhysicalDesignRoutingWorkBudget) throws -> Bool = { first, second, work in
            try arena.isSubset(first, of: second, budget: &work)
        }
        var search = PhysicalDesignRoutingSearch(maximumLabels: 5)
        let meet = PhysicalDesignRoutingSearch.Node(x: 2, y: 0, layer: 2)
        try search.append(node: .init(x: 0, y: 0, layer: 2), rootAccess: 0, history: ab, previous: nil, contact: nil, budget: &budget, isSubset: subset)
        try search.append(node: meet, rootAccess: 0, history: ab, previous: 0, contact: nil, budget: &budget, isSubset: subset)
        try search.append(node: .init(x: 0, y: 1, layer: 2), rootAccess: 1, history: onlyA, previous: nil, contact: nil, budget: &budget, isSubset: subset)
        try search.append(node: .init(x: 1, y: 1, layer: 2), rootAccess: 1, history: onlyA, previous: 2, contact: nil, budget: &budget, isSubset: subset)
        try search.append(node: meet, rootAccess: 1, history: onlyA, previous: 3, contact: nil, budget: &budget, isSubset: subset)
        #expect(try !search.contains(node: meet, history: onlyA, distance: 1, hasPredecessor: true, budget: &budget, isSubset: subset))
        #expect(try !search.contains(node: meet, history: ab, distance: 0, hasPredecessor: true, budget: &budget, isSubset: subset))
        var popped: Set<Int> = []
        while let index = try search.next(budget: &budget) { popped.insert(index) }
        #expect(popped.contains(1) && popped.contains(4))
    }

    @Test("retired heap entries still consume quota and observe cancellation")
    func retiredHeapConstraints() async throws {
        var search = PhysicalDesignRoutingSearch(maximumLabels: 5)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let node = PhysicalDesignRoutingSearch.Node(x: 2, y: 0, layer: 2)
        try search.append(node: .init(x: 0, y: 0, layer: 2), rootAccess: 0, history: 1, previous: nil, contact: nil, budget: &budget)
        try search.append(node: .init(x: 1, y: 0, layer: 2), rootAccess: 0, history: 1, previous: 0, contact: nil, budget: &budget)
        try search.append(node: node, rootAccess: 0, history: 1, previous: 1, contact: nil, budget: &budget)
        try search.append(node: .init(x: 2, y: 1, layer: 2), rootAccess: 1, history: 1, previous: nil, contact: nil, budget: &budget)
        try search.append(node: node, rootAccess: 1, history: 1, previous: 3, contact: nil, budget: &budget)
        #expect(try search.next(budget: &budget) == 0)
        #expect(try search.next(budget: &budget) == 3)
        #expect(try search.next(budget: &budget) == 1)
        #expect(try search.next(budget: &budget) == 4)
        var exhausted = PhysicalDesignRoutingWorkBudget(caller: 0)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) { try search.next(budget: &exhausted) }
        let frozen = search
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var cancelled = frozen, work = PhysicalDesignRoutingWorkBudget(caller: nil)
            do { _ = try cancelled.next(budget: &work); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        #expect(await task.value)
        #expect(try search.next(budget: &budget) == nil)
        #expect(search.labels[2].previous == 1 && search.labels[4].rootAccess == 1)
    }

    @Test("a seed cannot prune or retire a progressed target-eligible label", arguments: [false, true])
    func seedAcceptanceCapability(_ seedFirst: Bool) throws {
        var search = PhysicalDesignRoutingSearch(maximumLabels: 3)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let root = PhysicalDesignRoutingSearch.Node(x: 0, y: 0, layer: 2)
        let target = PhysicalDesignRoutingSearch.Node(x: 1, y: 0, layer: 2)
        try search.append(node: root, rootAccess: 0, history: 0, previous: nil, contact: nil, budget: &budget)
        if seedFirst {
            try search.append(node: target, rootAccess: 1, history: 0, previous: nil, contact: nil, budget: &budget)
            #expect(try !search.contains(node: target, history: 0, distance: 1, hasPredecessor: true, budget: &budget))
            try search.append(node: target, rootAccess: 0, history: 0, previous: 0, contact: nil, budget: &budget)
        } else {
            try search.append(node: target, rootAccess: 0, history: 0, previous: 0, contact: nil, budget: &budget)
            try search.append(node: target, rootAccess: 1, history: 0, previous: nil, contact: nil, budget: &budget)
        }
        let progressed = seedFirst ? 2 : 1, seed = seedFirst ? 1 : 2
        #expect(search.labels.count == 3 && search.labels[progressed].distance == 1 && search.labels[seed].distance == 0)
        try search.append(node: target, rootAccess: 9, history: 0, previous: nil, contact: nil, budget: &budget)
        try search.append(node: target, rootAccess: 8, history: 0, previous: 0, contact: nil, budget: &budget)
        #expect(search.labels.count == 3)
        var popped: [Int] = []
        while let index = try search.next(budget: &budget) { popped.append(index) }
        #expect(popped.count == 3 && popped.contains(progressed) && popped.contains(seed))
        let predecessor = try #require(search.labels[progressed].previous)
        #expect(predecessor == 0 && search.labels[progressed].node != search.labels[predecessor].node)
        #expect(search.labels[progressed].rootAccess == 0 && search.labels[seed].previous == nil)
    }

    private func contact(_ id: String, x: Int64) -> PhysicalDesignSnapshot.Via {
        .init(id: id, netID: "N", x: x, y: 1000, lowerLayer: 2, upperLayer: 3, master: "hv")
    }

    private func fixture() async throws -> PhysicalDesignProcessGeometry {
        var (request, store) = try await ProcessGeometryTests().fixtureSources()
        let original = try #require(request.processAssets["tech"])
        var text = try #require(String(data: await store.read(original), encoding: .utf8))
        text = text.replacingOccurrences(of: "WIDTH 0.05 ; SPACING 0.05 ;", with: "WIDTH 0.17 ; SPACING 0.19 ;")
        text = text.replacingOccurrences(of: "RECT -0.025 -0.025 0.025 0.025 ;", with: "RECT -0.085 -0.085 0.085 0.085 ;")
        text = text.replacingOccurrences(of: "RECT -0.1 -0.1 0.1 0.1 ;", with: "RECT -0.2 -0.2 0.2 0.2 ;")
        let begin = try #require(text.range(of: "VIA hv DEFAULT")), end = try #require(text.range(of: "END hv"))
        let alias = String(text[begin.lowerBound..<end.upperBound]).replacingOccurrences(of: "hv", with: "alias")
        let bytes = Data(text.replacingOccurrences(of: "END LIBRARY", with: alias + "\nEND LIBRARY").utf8)
        let source = try await store.registerInput(bytes, relativePath: "inputs/history-vias.lef", kind: .technology, format: .lef)
        var manifest = try PDKManifestCodec.decode(data: await store.read(request.requireBinding(for: request.pdk.manifest)))
        let index = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[index].path = source.path
        manifest.assets[index].sha256 = source.reference.digest.hexadecimalValue
        manifest.assets[index].byteCount = Int64(bytes.count)
        let binding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/history-process.json", kind: .technology, format: .json)
        let previousManifest = request.pdk.manifest
        request.inputBindings.removeAll { $0.reference == previousManifest || $0 == original }
        request.pdk = try .init(manifest: binding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: binding),
            processID: request.pdk.processID, version: request.pdk.version)
        request.processAssets["tech"] = source
        request.inputBindings.append(contentsOf: [binding, source])
        request.inputs = request.inputBindings.map(\.reference)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        return try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
    }
}
