import Synchronization
import TimingCore

final class NativePhysicalDesignPlacementTimingBudget: LibertySourceResourceAccounting {
    private struct State { var input: UInt64 = 0; var live: UInt64 = 0; var work: UInt64 = 0; var evidence: UInt64 = 0 }
    private let state = Mutex(State())
    let reference: PhysicalDesignPlacementTimingReference
    private let deadline: ContinuousClock.Instant
    init(_ reference: PhysicalDesignPlacementTimingReference) throws {
        guard reference.maximumInputBytes > 0, reference.maximumLiveBytes > 0, reference.maximumWorkUnits > 0,
              reference.maximumPathWorkUnitsPerAnalysis > 0, reference.maximumPathWorkUnitsPerAnalysis <= reference.maximumWorkUnits,
              reference.maximumPathStates > 0, reference.maximumEvidenceBytes > 0,
              reference.timeoutNanoseconds > 0, reference.timeoutNanoseconds <= UInt64(Int64.max) else {
            throw PhysicalDesignPlacementTimingError.invalidProfile("Timing placement requires explicit positive resource limits")
        }
        self.reference = reference
        deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(reference.timeoutNanoseconds)))
    }
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw PhysicalDesignPlacementTimingError.deadline }
    }
    func chargeInput(_ count: UInt64) throws { try charge(count, key: \.input, limit: reference.maximumInputBytes, name: "input bytes") }
    func chargeEvidence(_ count: UInt64) throws { try charge(count, key: \.evidence, limit: reference.maximumEvidenceBytes, name: "retained evidence bytes") }
    func retainEvidenceStorage(_ count: UInt64) throws {
        try charge(count, key: \.live, limit: reference.maximumLiveBytes, name: "retained candidate evidence storage")
    }
    func chargeWork(_ amount: UInt64) throws { try charge(amount, key: \.work, limit: reference.maximumWorkUnits, name: "source and reserved path work") }
    var chargedWorkUnits: UInt64 { state.withLock { $0.work } }
    private func charge(_ amount: UInt64, key: WritableKeyPath<State, UInt64>, limit: UInt64, name: String) throws {
        try check()
        try state.withLock { value in
            let next = value[keyPath: key].addingReportingOverflow(amount)
            guard !next.overflow, next.partialValue <= limit else { throw PhysicalDesignPlacementTimingError.resourceLimit(name) }
            value[keyPath: key] = next.partialValue
        }
    }
    func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
        try charge(byteCount, key: \.live, limit: reference.maximumLiveBytes, name: "live source storage")
        return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { $0.live -= byteCount } }
    }
}
