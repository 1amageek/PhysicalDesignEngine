struct PhysicalDesignDEFText {
    private(set) var value = ""
    private var byteCount: UInt64 = 0
    private let limit: UInt64?

    init(limit: UInt64?) { self.limit = limit }

    mutating func append(_ fragment: String) throws {
        try Task.checkCancellation()
        let (next, overflow) = byteCount.addingReportingOverflow(UInt64(fragment.utf8.count))
        guard !overflow else { throw PhysicalDesignStandardLayoutExportError.limitExceeded(.outputBytes) }
        if let limit, next > limit { throw PhysicalDesignStandardLayoutExportError.limitExceeded(.outputBytes) }
        byteCount = next
        value.append(contentsOf: fragment)
    }

    mutating func line(_ fragment: String) throws {
        try append(fragment)
        try append("\n")
    }
}
