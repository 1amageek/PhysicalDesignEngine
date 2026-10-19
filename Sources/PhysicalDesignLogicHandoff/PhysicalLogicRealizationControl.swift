import LogicKernelCore

struct PhysicalLogicRealizationControl: LogicRunControlling {
    private let deadline: ContinuousClock.Instant
    init(timeoutNanoseconds: UInt64) {
        deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(clamping: timeoutNanoseconds)))
    }
    func checkpoint() throws(LogicKernelError) {
        if Task.isCancelled { throw .cancelled }
        if ContinuousClock.now >= deadline { throw .deadlineExceeded }
    }
}
