import LEF

/// Invocation-owned source-rule compilation; lookup does not allocate or reread source bytes.
struct PhysicalDesignRoutingSpacingRule: Sendable {
    private let scalar: Int64?
    private let widths: [Int64]
    private let lengths: [Int64]
    private let values: [Int64]

    var usesParallelRunLength: Bool { scalar == nil }

    init(source: borrowing LEFLayerDef, units: Int) throws {
        if let table = source.spacingTable {
            guard source.spacing == nil, !table.widthEntries.isEmpty, !table.parallelRunLengths.isEmpty else {
                throw PhysicalDesignTechnologyError.invalid("Spacing table requires complete axes and cannot coexist with scalar SPACING.")
            }
            let (count, overflow) = table.widthEntries.count.multipliedReportingOverflow(by: table.parallelRunLengths.count)
            guard !overflow else { throw PhysicalDesignTechnologyError.invalid("Spacing table storage exceeds the index range.") }
            var compiledLengths: [Int64] = [], compiledWidths: [Int64] = [], compiledValues: [Int64] = []
            compiledLengths.reserveCapacity(table.parallelRunLengths.count)
            compiledWidths.reserveCapacity(table.widthEntries.count)
            compiledValues.reserveCapacity(count)
            var previousLength: Double?
            for length in table.parallelRunLengths {
                if let previousLength, length <= previousLength { throw PhysicalDesignTechnologyError.invalid("Spacing length axis must increase.") }
                compiledLengths.append(try PhysicalDesignProcessInputs.dbu(length, units: units, field: "PARALLELRUNLENGTH", signed: true))
                previousLength = length
            }
            var previousWidth: Double?
            for (row, entry) in table.widthEntries.enumerated() {
                try Task.checkCancellation()
                guard entry.spacings.count == compiledLengths.count else { throw PhysicalDesignTechnologyError.invalid("Spacing matrix has an incomplete row.") }
                if let previousWidth, entry.width <= previousWidth { throw PhysicalDesignTechnologyError.invalid("Spacing width axis must increase.") }
                compiledWidths.append(try PhysicalDesignProcessInputs.dbu(entry.width, units: units, field: "SPACINGTABLE WIDTH"))
                previousWidth = entry.width
                for column in entry.spacings.indices {
                    let value = try PhysicalDesignProcessInputs.dbu(entry.spacings[column], units: units, field: "SPACINGTABLE spacing")
                    guard column == 0 || value >= compiledValues.last!, row == 0 || value >= compiledValues[(row - 1) * compiledLengths.count + column] else {
                        throw PhysicalDesignTechnologyError.invalid("Spacing values must not decrease along either axis.")
                    }
                    compiledValues.append(value)
                }
            }
            scalar = nil; widths = compiledWidths; lengths = compiledLengths; values = compiledValues
        } else {
            scalar = try PhysicalDesignProcessInputs.dbu(source.spacing, units: units, field: "\(source.name).SPACING")
            widths = []; lengths = []; values = []
        }
    }

    func spacing(maximumWidth: Int64, parallelLength: Int64) throws -> Int64 {
        guard maximumWidth >= 0 else { throw PhysicalDesignTechnologyError.invalid("Spacing lookup requires an actual nonnegative width.") }
        if let scalar { return scalar }
        return values[index(widths, below: maximumWidth) * lengths.count + index(lengths, below: parallelLength)]
    }

    func forEachSpacing(_ body: (Int64) throws -> Void) rethrows {
        if let scalar { try body(scalar) }
        else { for value in values { try body(value) } }
    }

    private func index(_ axis: borrowing [Int64], below value: Int64) -> Int {
        var lower = 0, upper = axis.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if axis[middle] < value { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
}
