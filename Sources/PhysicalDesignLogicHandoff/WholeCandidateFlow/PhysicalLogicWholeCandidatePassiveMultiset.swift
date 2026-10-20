import PEXCore

/// Exact kind/oriented-canonical-endpoint/binary64-bit multiplicity, independent of element IDs.
internal enum PhysicalLogicWholeCandidatePassiveMultiset {
    static func requireEqual(_ original: ParasiticIR, _ decoded: ParasiticIR,
        control: PhysicalLogicWholeCandidateControl) throws {
        let count = original.elements.count
        guard original.units == decoded.units, count == decoded.elements.count,
              count <= control.limits.maximumAssociations else {
            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Cold passive count or units differ")
        }
        let (minimum, overflow) = count.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Passive count overflow") }
        var capacity = 1
        while capacity < minimum {
            try control.check()
            let next = capacity.multipliedReportingOverflow(by: 2)
            guard !next.overflow else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Passive index overflow") }
            capacity = next.partialValue
        }
        let slotsLease = try control.slots(Int.self, count: capacity)
        let countsLease = try control.slots(Int.self, count: count)
        defer { withExtendedLifetime((slotsLease, countsLease)) {} }
        try control.check(try PhysicalLogicWholeCandidateControl.sum(UInt64(capacity), UInt64(count)))
        var slots = [Int](repeating: -1, count: capacity), counts = [Int](repeating: 0, count: count)
        for index in 0..<count {
            try control.check()
            let element = original.elements[index]
            var slot = Int(try hash(element, control: control) & UInt64(capacity - 1))
            while slots[slot] != -1 {
                try control.check()
                if try same(element, original.elements[slots[slot]], control: control) { break }
                slot = (slot + 1) & (capacity - 1)
            }
            if slots[slot] == -1 { slots[slot] = index }
            // A bucket count is bounded by the already checked total element count.
            counts[slots[slot]] += 1
        }
        for element in decoded.elements {
            try control.check()
            var slot = Int(try hash(element, control: control) & UInt64(capacity - 1))
            while slots[slot] != -1 {
                try control.check()
                if try same(element, original.elements[slots[slot]], control: control) { break }
                slot = (slot + 1) & (capacity - 1)
            }
            guard slots[slot] != -1, counts[slots[slot]] > 0 else {
                throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Cold passive kind/endpoints/value bits differ")
            }
            counts[slots[slot]] -= 1
        }
        for remaining in counts {
            try control.check()
            guard remaining == 0 else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Cold passive multiplicity differs") }
        }
    }
    private static func same(_ a: ParasiticElement, _ b: ParasiticElement,
        control: PhysicalLogicWholeCandidateControl) throws -> Bool {
        guard a.kind == b.kind, a.value.bitPattern == b.value.bitPattern,
              try same(a.nodeA, b.nodeA, control: control) else { return false }
        switch (a.nodeB, b.nodeB) {
        case (nil, nil): return true
        case (.some(let a), .some(let b)): return try same(a, b, control: control)
        default: return false
        }
    }
    private static func same(_ a: NodeRef, _ b: NodeRef,
        control: PhysicalLogicWholeCandidateControl) throws -> Bool {
        guard try control.same(a.netName.value, b.netName.value) else { return false }
        return try control.same(a.nodeName.value, b.nodeName.value)
    }
    private static func hash(_ element: ParasiticElement,
        control: PhysicalLogicWholeCandidateControl) throws -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        func byte(_ value: UInt8) { hash = (hash ^ UInt64(value)) &* 1099511628211 }
        func text(_ value: String) throws {
            try control.text(value)
            var count = 0
            for b in value.utf8 {
                if count.isMultiple(of: 256) { try control.check() }
                byte(b); count += 1
            }
            // Length, not a delimiter assumption, disambiguates arbitrary canonical names.
            var length = UInt64(value.utf8.count)
            for _ in 0..<8 { byte(UInt8(truncatingIfNeeded: length)); length >>= 8 }
        }
        switch element.kind {
        case .resistor: byte(1)
        case .capacitor: byte(2)
        case .coupling: byte(3)
        case .inductor: byte(4)
        }
        try text(element.nodeA.netName.value); try text(element.nodeA.nodeName.value)
        if let b = element.nodeB { byte(1); try text(b.netName.value); try text(b.nodeName.value) } else { byte(0) }
        var bits = element.value.bitPattern
        for _ in 0..<8 { byte(UInt8(truncatingIfNeeded: bits)); bits >>= 8 }
        return hash
    }
}
