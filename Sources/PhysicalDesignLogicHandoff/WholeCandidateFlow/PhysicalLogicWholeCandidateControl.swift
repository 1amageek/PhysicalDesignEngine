import CoreSpice
import CoreSpiceIO
import Synchronization

/// Immutable per-operation policy; the original invocation accountant owns every charge.
internal final class PhysicalLogicWholeCandidateControl: SPICESourceResourceAccounting {
    let resources: any SPICESourceResourceAccounting
    let cancellation: CancellationToken
    let limits: PhysicalLogicWholeCandidateFlowLimits
    private let joinBytes: Mutex<UInt64>
    private let storage: SPICESourceStorageReservation
    var joinAccounting: any SPICESourceResourceAccounting { JoinAccounting(owner: self) }
    private init(resources: any SPICESourceResourceAccounting, cancellation: CancellationToken,
        limits: PhysicalLogicWholeCandidateFlowLimits, storage: SPICESourceStorageReservation) {
        self.resources = resources; self.cancellation = cancellation; self.limits = limits
        self.storage = storage; joinBytes = Mutex(storage.byteCount)
    }
    static func make(resources: any SPICESourceResourceAccounting, cancellation: CancellationToken,
        limits: PhysicalLogicWholeCandidateFlowLimits) throws -> PhysicalLogicWholeCandidateControl {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw PhysicalLogicWholeCandidateFlowFailure.cancelled }
        var bytes: UInt64 = 0
        // Fixed logical stored payload; each field is padded to its actual alignment before admission.
        func field<T>(_ type: T.Type) throws {
            let alignment = UInt64(MemoryLayout<T>.alignment)
            let remainder = bytes % alignment
            if remainder != 0 { bytes = try sum(bytes, alignment - remainder) }
            bytes = try sum(bytes, UInt64(MemoryLayout<T>.stride))
        }
        try field((any SPICESourceResourceAccounting).self)
        try field(CancellationToken.self); try field(PhysicalLogicWholeCandidateFlowLimits.self)
        // Mutex stores the same UInt64 quota on every supported host execution path.
        let mutexAlignment = UInt64(MemoryLayout<Mutex<UInt64>>.alignment)
        let remainder = bytes % mutexAlignment
        if remainder != 0 { bytes = try sum(bytes, mutexAlignment - remainder) }
        bytes = try sum(bytes, UInt64(MemoryLayout<Mutex<UInt64>>.stride))
        try field(SPICESourceStorageReservation.self)
        guard bytes <= limits.maximumJoinBytes else { throw PhysicalLogicWholeCandidateFlowFailure.resource(SPICESourceStorageError.invalidCapacity) }
        let storage: SPICESourceStorageReservation
        do {
            try resources.checkCancellation()
            guard !cancellation.isCancelled, !Task.isCancelled else { throw PhysicalLogicWholeCandidateFlowFailure.cancelled }
            storage = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
            guard !cancellation.isCancelled, !Task.isCancelled else { throw PhysicalLogicWholeCandidateFlowFailure.cancelled }
        } catch let error as PhysicalLogicWholeCandidateFlowFailure { throw error }
        catch { throw PhysicalLogicWholeCandidateFlowFailure.resource(error) }
        return Self(resources: resources, cancellation: cancellation, limits: limits, storage: storage)
    }
    func check(_ units: UInt64 = 1) throws {
        try checkCancellation()
        try charge(.retainedElements, units: units)
    }
    private func resourceFailure(_ error: any Error) -> PhysicalLogicWholeCandidateFlowFailure {
        if cancellation.isCancelled || Task.isCancelled || error is CancellationError { return .cancelled }
        if let failure = error as? PhysicalLogicWholeCandidateFlowFailure { return failure }
        return .resource(error)
    }
    func checkCancellation() throws {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw PhysicalLogicWholeCandidateFlowFailure.cancelled }
        do { try resources.checkCancellation() } catch { throw resourceFailure(error) }
        guard !cancellation.isCancelled, !Task.isCancelled else { throw PhysicalLogicWholeCandidateFlowFailure.cancelled }
    }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        try checkCancellation()
        do { try resources.charge(kind, units: units) } catch { throw resourceFailure(error) }
        try checkCancellation()
    }
    func chargeHashedBytes(_ byteCount: UInt64) throws {
        try checkCancellation()
        do { try resources.chargeHashedBytes(byteCount) } catch { throw resourceFailure(error) }
        try checkCancellation()
    }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        try checkCancellation()
        let lease: SPICESourceStorageReservation
        do { lease = try resources.reserveStorage(kind: kind, byteCount: byteCount) }
        catch { throw resourceFailure(error) }
        try checkCancellation()
        return lease
    }
    func text(_ value: String) throws {
        try check()
        try charge(.projectedBytes, units: UInt64(value.utf8.count))
        try check()
    }
    func same(_ lhs: String, _ rhs: String) throws -> Bool {
        try text(lhs); try text(rhs)
        var a = lhs.utf8.makeIterator(), b = rhs.utf8.makeIterator(), count = 0
        while let left = a.next() {
            if count.isMultiple(of: 256) { try check() }
            guard let right = b.next(), left == right else { return false }
            count += 1
        }
        return b.next() == nil
    }
    func symbol(_ lhs: String, _ rhs: String) throws -> Bool {
        try text(lhs); try text(rhs)
        var left = lhs.utf8.makeIterator(), right = rhs.utf8.makeIterator(), count = 0
        while let a = left.next() {
            if count.isMultiple(of: 256) { try check() }
            guard let b = right.next() else { return false }
            let x = (65...90).contains(a) ? a + 32 : a
            let y = (65...90).contains(b) ? b + 32 : b
            guard x == y else { return false }
            count += 1
        }
        return right.next() == nil
    }
    func reserve(_ bytes: UInt64, kind: SPICESourceStorageKind = .temporaryBytes)
        throws -> SPICESourceStorageReservation {
        try check()
        try joinBytes.withLock { retained in
            let (next, overflow) = retained.addingReportingOverflow(bytes)
            guard !overflow else { throw PhysicalLogicWholeCandidateFlowFailure.resource(SPICESourceStorageError.arithmeticOverflow) }
            guard next <= limits.maximumJoinBytes else { throw PhysicalLogicWholeCandidateFlowFailure.resource(SPICESourceStorageError.invalidCapacity) }
            retained = next
        }
        let original: SPICESourceStorageReservation
        do { original = try reserveStorage(kind: kind, byteCount: bytes) }
        catch {
            joinBytes.withLock { $0 -= bytes }
            throw error
        }
        return SPICESourceStorageReservation(kind: kind, byteCount: bytes) { [self] in
            // The external release callback runs only after the short local quota lock is released.
            withExtendedLifetime(original) {}
            joinBytes.withLock { $0 -= bytes }
        }
    }
    static func sum(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (n, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Capacity overflow") }
        return n
    }
    static func product(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (n, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Capacity overflow") }
        return n
    }
    func slots<T>(_ type: T.Type, count: Int, kind: SPICESourceStorageKind = .temporaryBytes)
        throws -> SPICESourceStorageReservation {
        guard count >= 0 else { throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Negative capacity") }
        let bytes = try Self.sum(UInt64(MemoryLayout<[T]>.stride), Self.product(UInt64(count), UInt64(MemoryLayout<T>.stride)))
        return try reserve(bytes, kind: kind)
    }
    private struct JoinAccounting: SPICESourceResourceAccounting {
        let owner: PhysicalLogicWholeCandidateControl
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { try owner.charge(kind, units: units) }
        func chargeHashedBytes(_ byteCount: UInt64) throws { try owner.chargeHashedBytes(byteCount) }
        func checkCancellation() throws { try owner.checkCancellation() }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try owner.reserve(byteCount, kind: kind)
        }
    }
    static func failure(_ error: any Error) -> PhysicalLogicWholeCandidateFlowFailure {
        if let failure = error as? PhysicalLogicWholeCandidateFlowFailure { return failure }
        if error is CancellationError { return .cancelled }
        return .native(error)
    }
}
