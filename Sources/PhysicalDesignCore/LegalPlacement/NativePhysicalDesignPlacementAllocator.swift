import DEF
import Foundation

struct NativePhysicalDesignPlacementAllocator: PhysicalDesignPlacementAllocating {
    private struct Occupancy {
        let rect: PhysicalDesignSnapshot.Rect
        let spacing: Int64
        let isBlockage: Bool
    }

    func allocate(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
        processGeometry: PhysicalDesignProcessGeometry?) throws -> PhysicalDesignPlacementAllocation {
        try Task.checkCancellation()
        guard let core = input.core else { throw PhysicalDesignPlacementError.capacity("core") }
        try check(core)
        let rows = input.rows.sorted { $0.id < $1.id }
        let occupiedCount = try add(input.blockages.count, try add(input.cells.count, 1))
        let structural = try multiply(try multiply(try multiply(input.cells.count, rows.count), 8), occupiedCount)
        let ceiling = min(configuration.maximumPlacementCandidateChecks ?? structural, structural)
        var occupancy = try input.blockages.map { rect in
            try check(rect)
            return Occupancy(rect: rect, spacing: 0, isBlockage: true)
        }
        for cell in input.cells.filter(\.locked).sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            let rect = bounds(cell)
            try check(rect)
            let compatible = try rows.contains { row in
                let end = try rowEnd(row)
                let offset = try subtract(cell.x, row.originX)
                return cell.y == row.originY && offset >= 0 && offset.isMultiple(of: row.siteWidth)
                    && rect.maxX <= end && cell.height <= row.height
                    && (processGeometry?.canPlace(cell, on: row) ?? true)
            }
            guard cell.placed, core.contains(rect), compatible,
                !occupancy.contains(where: { $0.rect.intersects(rect) }) else {
                throw PhysicalDesignPlacementError.invalidLockedCell(cell.id)
            }
            occupancy.append(.init(rect: rect, spacing: configuration.placementSpacing, isBlockage: false))
        }
        var output = input
        let pinIndices = Dictionary(grouping: output.pins.indices, by: { output.pins[$0].cellID })
        let indices = output.cells.indices.filter { !output.cells[$0].locked }.sorted { output.cells[$0].id < output.cells[$1].id }
        var checks = 0
        var blockageConflicts = 0
        for index in indices {
            try Task.checkCancellation()
            let previous = output.cells[index]
            let orientations = processGeometry == nil ? [previous.orientation]
                : [previous.orientation] + DEFOrientation.allCases.filter { $0 != previous.orientation }
            var selected: PhysicalDesignSnapshot.Cell?
            search: for row in rows {
                let end = try rowEnd(row)
                for orientation in orientations {
                    var cell = previous
                    cell.orientation = orientation
                    if let processGeometry {
                        let size = try processGeometry.dimensions(master: cell.master, orientation: orientation)
                        cell.width = size.width
                        cell.height = size.height
                    }
                    guard cell.height <= row.height, processGeometry?.canPlace(cell, on: row) ?? true else { continue }
                    cell.y = row.originY
                    let top = try sum(cell.y, cell.height)
                    let intervals = occupancy.filter { $0.rect.y < top && $0.rect.maxY > cell.y }
                    // Every free interval begins at the row origin or an occupied right edge.
                    // Event storage scales with geometry, never with the row's site count.
                    var events: Set<Int64> = [row.originX]
                    for interval in intervals {
                        let boundary = try sum(interval.rect.maxX, interval.spacing)
                        events.insert(try aligned(max(row.originX, boundary), on: row))
                    }
                    for x in events.sorted() {
                        try Task.checkCancellation()
                        let right = try sum(x, cell.width)
                        guard x >= row.originX, right <= end else { continue }
                        guard checks < ceiling else { throw PhysicalDesignPlacementError.candidateBudget }
                        checks += 1
                        cell.x = x
                        let rect = bounds(cell)
                        guard core.contains(rect) else { continue }
                        var conflict = false
                        for interval in intervals {
                            let left = try subtract(interval.rect.x, interval.spacing)
                            let occupiedRight = try sum(interval.rect.maxX, interval.spacing)
                            if rect.x < occupiedRight && rect.maxX > left {
                                if interval.isBlockage { blockageConflicts += 1 }
                                conflict = true
                                break
                            }
                        }
                        guard !conflict else { continue }
                        cell.placed = true
                        selected = cell
                        break search
                    }
                }
            }
            guard let cell = selected else { throw PhysicalDesignPlacementError.capacity(previous.id) }
            for pinIndex in pinIndices[cell.id, default: []] {
                if cell.orientation != previous.orientation, let processGeometry {
                    output.pins[pinIndex] = try processGeometry.referencePin(output.pins[pinIndex], for: cell)
                } else {
                    output.pins[pinIndex].x = try sum(cell.x, subtract(output.pins[pinIndex].x, previous.x))
                    output.pins[pinIndex].y = try sum(cell.y, subtract(output.pins[pinIndex].y, previous.y))
                }
            }
            output.cells[index] = cell
            occupancy.append(.init(rect: bounds(cell), spacing: configuration.placementSpacing, isBlockage: false))
        }
        return .init(snapshot: output, candidateChecks: checks, candidateCeiling: ceiling,
            structuralCeiling: structural, blockageConflictCount: blockageConflicts)
    }

    private func bounds(_ cell: PhysicalDesignSnapshot.Cell) -> PhysicalDesignSnapshot.Rect {
        .init(x: cell.x, y: cell.y, width: cell.width, height: cell.height)
    }

    private func check(_ rect: PhysicalDesignSnapshot.Rect) throws {
        guard rect.width > 0, rect.height > 0 else { throw PhysicalDesignPlacementError.capacity("geometry") }
        _ = try sum(rect.x, rect.width)
        _ = try sum(rect.y, rect.height)
    }

    private func rowEnd(_ row: PhysicalDesignSnapshot.Row) throws -> Int64 {
        let (extent, overflow) = row.siteCount.multipliedReportingOverflow(by: row.siteWidth)
        guard !overflow, row.siteWidth > 0, row.siteCount > 0 else { throw PhysicalDesignPlacementError.arithmeticOverflow }
        return try sum(row.originX, extent)
    }

    private func aligned(_ x: Int64, on row: PhysicalDesignSnapshot.Row) throws -> Int64 {
        let offset = try subtract(x, row.originX)
        let quotient = offset / row.siteWidth
        let sites = try sum(quotient, offset.isMultiple(of: row.siteWidth) ? 0 : 1)
        let (extent, overflow) = sites.multipliedReportingOverflow(by: row.siteWidth)
        guard !overflow else { throw PhysicalDesignPlacementError.arithmeticOverflow }
        return try sum(row.originX, extent)
    }

    private func sum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PhysicalDesignPlacementError.arithmeticOverflow }
        return value
    }

    private func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else { throw PhysicalDesignPlacementError.arithmeticOverflow }
        return value
    }

    private func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PhysicalDesignPlacementError.arithmeticOverflow }
        return value
    }

    private func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw PhysicalDesignPlacementError.arithmeticOverflow }
        return value
    }
}
