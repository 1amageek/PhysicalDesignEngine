import LayoutIR
import MaskGeometry

/// Selects actual fixed shapes under the caller's cumulative routing budget.
struct PhysicalDesignFixedViaSelection {
    static func select(_ requested: PhysicalDesignSnapshot.Via, within bounds: PhysicalDesignSnapshot.Rect,
                       geometry: PhysicalDesignProcessGeometry, budget: inout PhysicalDesignRoutingWorkBudget,
                       isLegal: (PhysicalDesignSnapshot.Via, [IRBoundary], inout PhysicalDesignRoutingWorkBudget) throws -> Bool)
        throws -> PhysicalDesignSnapshot.Via? {
        let names: [String]
        if let name = requested.master {
            guard geometry.vias[name] != nil else {
                throw PhysicalDesignTechnologyError.invalid("Via \(requested.id) references an undeclared fixed master.")
            }
            names = [name]
        } else {
            try budget.admitSort(geometry.vias.count)
            names = geometry.vias.keys.sorted().filter { name in
                guard let via = geometry.vias[name] else { return false }
                return via.definition.isDefault && Int(via.lowerLayer) == requested.lowerLayer
                    && Int(via.upperLayer) == requested.upperLayer
            }
        }
        try budget.extend(names.count)
        for name in names {
            try budget.admit()
            guard let source = geometry.vias[name] else {
                throw PhysicalDesignTechnologyError.invalid("An admitted fixed VIA source disappeared.")
            }
            guard Int(source.lowerLayer) == requested.lowerLayer, Int(source.upperLayer) == requested.upperLayer else {
                throw PhysicalDesignTechnologyError.invalid("Via \(requested.id) layer pair contradicts its fixed master.")
            }
            var cost = source.shapes.count
            for shape in source.shapes {
                let sum = cost.addingReportingOverflow(shape.points.count)
                guard !sum.overflow else {
                    throw PhysicalDesignTechnologyError.invalid("Fixed VIA shape work exceeds the index range.")
                }
                cost = sum.partialValue
            }
            try budget.extend(cost); try budget.charge(cost)
            var candidate = requested; candidate.master = name
            let shapes = try geometry.viaShapes(master: name, x: candidate.x, y: candidate.y)
            guard shapes.allSatisfy({ $0.points.allSatisfy { bounds.containsPoint(x: Int64($0.x), y: Int64($0.y)) } }) else { continue }
            guard let x = Int32(exactly: candidate.x), let y = Int32(exactly: candidate.y) else {
                throw PhysicalDesignTechnologyError.invalid("Fixed VIA origin exceeds the geometry backend range.")
            }
            var centered = true
            for layer in [source.lowerLayer, source.upperLayer] {
                if !Region(layer: layer, polygons: shapes.filter { $0.layer == layer }).contains(.init(x: x, y: y)) {
                    centered = false; break
                }
            }
            guard centered, try isLegal(candidate, shapes, &budget) else { continue }
            return candidate
        }
        return nil
    }

    /// Retained pairs were validated before search; only new physical cut pairs need replay.
    static func cutsFit(_ shapes: [IRBoundary], geometry: PhysicalDesignProcessGeometry,
                        against existing: [PhysicalDesignSnapshot.Via], sourceCuts: [IRBoundary],
                        budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        for index in shapes.indices where geometry.sourceLayers[shapes[index].layer]?.type == .cut {
            let candidate = shapes[index]
            for prior in shapes.indices where prior < index && shapes[prior].layer == candidate.layer {
                if try !separated(candidate, from: shapes[prior], geometry: geometry, budget: &budget) { return false }
            }
            for other in sourceCuts {
                try charge(1, budget: &budget)
                if other.layer == candidate.layer,
                   try !separated(candidate, from: other, geometry: geometry, budget: &budget) { return false }
            }
            for via in existing {
                try charge(1, budget: &budget)
                guard let name = via.master, let source = geometry.vias[name] else {
                    throw PhysicalDesignTechnologyError.invalid("Candidate cut replay requires exact retained fixed masters.")
                }
                guard source.cutLayer == candidate.layer else { continue }
                var work = source.shapes.count
                for shape in source.shapes { work = try add(work, shape.points.count) }
                try charge(work, budget: &budget)
                let translated = try geometry.viaShapes(master: name, x: via.x, y: via.y)
                for other in translated where other.layer == candidate.layer {
                    if try !separated(candidate, from: other, geometry: geometry, budget: &budget) { return false }
                }
            }
        }
        return true
    }

    private static func separated(_ first: IRBoundary, from second: IRBoundary,
                                  geometry: PhysicalDesignProcessGeometry, budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        let firstCount = first.points.last == first.points.first ? first.points.count - 1 : first.points.count
        let secondCount = second.points.last == second.points.first ? second.points.count - 1 : second.points.count
        let pairs = firstCount.multipliedReportingOverflow(by: secondCount)
        guard firstCount >= 3, secondCount >= 3, !pairs.overflow else {
            throw PhysicalDesignTechnologyError.invalid("Candidate cut vertex-pair work is invalid or overflows.")
        }
        try charge(try add(pairs.partialValue, try add(firstCount, secondCount)), budget: &budget)
        return try PhysicalDesignFixedCutSeparation.separated(first, from: second,
            minimum: geometry.cutSpacings[first.layer] ?? 0)
    }

    private static func charge(_ amount: Int, budget: inout PhysicalDesignRoutingWorkBudget) throws {
        try budget.extend(amount); try budget.charge(amount)
    }

    private static func add(_ first: Int, _ second: Int) throws -> Int {
        let result = first.addingReportingOverflow(second)
        guard !result.overflow else { throw PhysicalDesignTechnologyError.invalid("Candidate cut work exceeds the index range.") }
        return result.partialValue
    }
}

extension PhysicalDesignProcessGeometry {
    /// Revalidates a retained explicit identity without repeating automatic search.
    func resolveVia(_ via: PhysicalDesignSnapshot.Via, within bounds: PhysicalDesignSnapshot.Rect) throws -> PhysicalDesignSnapshot.Via {
        guard let name = via.master else {
            throw PhysicalDesignTechnologyError.unsupported("Automatic fixed VIA selection requires the cumulative routing budget.")
        }
        guard let source = vias[name] else {
            throw PhysicalDesignTechnologyError.invalid("Via \(via.id) references an undeclared fixed master.")
        }
        guard Int(source.lowerLayer) == via.lowerLayer, Int(source.upperLayer) == via.upperLayer else {
            throw PhysicalDesignTechnologyError.invalid("Via \(via.id) layer pair contradicts its fixed master.")
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Center-joined source routes cannot use offset-access fixed contacts. Such named contacts remain unsupported until actual offset routing is implemented and verified.
        for layer in [source.lowerLayer, source.upperLayer] {
            guard Region(layer: layer, polygons: source.shapes.filter { $0.layer == layer }).contains(.init(x: 0, y: 0)) else {
                throw PhysicalDesignTechnologyError.unsupported("Via \(source.definition.name) requires offset access beyond the center-joined native profile.")
            }
        }
        guard try viaFits(via, within: bounds) else {
            throw PhysicalDesignTechnologyError.invalid("Via \(via.id) translated fixed footprint leaves its construction bounds.")
        }
        return via
    }
}
