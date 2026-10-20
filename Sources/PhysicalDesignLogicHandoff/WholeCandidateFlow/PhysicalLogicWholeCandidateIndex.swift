import CoreSpiceIO

/// Fixed, call-local source-symbol index. All slots are admitted before allocation.
internal struct PhysicalLogicWholeCandidateIndex {
    private let slots: [Int]
    private let lease: SPICESourceStorageReservation
    init(count: Int, control: PhysicalLogicWholeCandidateControl, key: (Int) throws -> String) throws {
        guard count >= 0, count <= control.limits.maximumAssociations else {
            throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Source index count exceeded")
        }
        let (minimum, overflow) = count.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Source index overflow") }
        var capacity = 1
        while capacity < minimum {
            try control.check()
            let doubled = capacity.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Source index overflow") }
            capacity = doubled.partialValue
        }
        let lease = try control.slots(Int.self, count: capacity)
        try control.check(UInt64(capacity))
        var slots = [Int](repeating: -1, count: capacity)
        for index in 0..<count {
            try control.check()
            let name = try key(index)
            var slot = Int(try Self.hash(name, control: control) & UInt64(capacity - 1))
            while slots[slot] != -1 {
                try control.check()
                guard try !control.symbol(name, key(slots[slot])) else {
                    throw PhysicalLogicWholeCandidateFlowFailure.source("A case-equivalent source symbol is duplicated")
                }
                slot = (slot + 1) & (capacity - 1)
            }
            slots[slot] = index
        }
        try control.check()
        self.slots = slots; self.lease = lease
    }
    func find(_ name: String, control: PhysicalLogicWholeCandidateControl,
        key: (Int) throws -> String) throws -> Int? {
        var slot = Int(try Self.hash(name, control: control) & UInt64(slots.count - 1))
        while slots[slot] != -1 {
            try control.check()
            if try control.symbol(name, key(slots[slot])) { return slots[slot] }
            slot = (slot + 1) & (slots.count - 1)
        }
        return nil
    }
    private static func hash(_ name: String, control: PhysicalLogicWholeCandidateControl) throws -> UInt64 {
        try control.text(name)
        var value: UInt64 = 14695981039346656037, count = 0
        for byte in name.utf8 {
            if count.isMultiple(of: 256) { try control.check() }
            let folded = (65...90).contains(byte) ? byte + 32 : byte
            value = (value ^ UInt64(folded)) &* 1099511628211
            count += 1
        }
        return value
    }
}
