import LayoutIR

extension PhysicalDesignProcessGeometry {
    /// Borrows exact projected contacts retained by the caller's immutable contact arena.
    func routingCutPairFits(_ candidate: borrowing PhysicalDesignSnapshot.Via,
                           shapes candidateShapes: borrowing [IRBoundary],
                           against other: borrowing PhysicalDesignSnapshot.Via,
                           otherShapes: borrowing [IRBoundary],
                           budget: inout PhysicalDesignRoutingWorkBudget) throws -> Bool {
        try budget.extend(1); try budget.charge(1)
        guard let candidateName = candidate.master, let candidateSource = vias[candidateName],
              let otherName = other.master, let otherSource = vias[otherName],
              candidate.lowerLayer == Int(candidateSource.lowerLayer),
              candidate.upperLayer == Int(candidateSource.upperLayer),
              other.lowerLayer == Int(otherSource.lowerLayer),
              other.upperLayer == Int(otherSource.upperLayer),
              sourceLayers[candidateSource.cutLayer]?.type == .cut,
              sourceLayers[otherSource.cutLayer]?.type == .cut else {
            throw PhysicalDesignTechnologyError.invalid("Cut pair requires exact declared fixed masters and matching layer pairs.")
        }
        var candidateCuts = 0, otherCuts = 0
        for index in candidateShapes.indices {
            try budget.extend(1); try budget.charge(1)
            let shape = candidateShapes[index]
            if shape.layer == candidateSource.cutLayer {
                let vertices = shape.points.count - (shape.points.first == shape.points.last ? 1 : 0)
                guard vertices >= 3 else { throw PhysicalDesignTechnologyError.invalid("Candidate contact lacks actual cut vertices.") }
                candidateCuts += 1
            }
        }
        for index in otherShapes.indices {
            try budget.extend(1); try budget.charge(1)
            let shape = otherShapes[index]
            if shape.layer == otherSource.cutLayer {
                let vertices = shape.points.count - (shape.points.first == shape.points.last ? 1 : 0)
                guard vertices >= 3 else { throw PhysicalDesignTechnologyError.invalid("Prior contact lacks actual cut vertices.") }
                otherCuts += 1
            }
        }
        guard candidateCuts > 0, otherCuts > 0 else {
            throw PhysicalDesignTechnologyError.invalid("Cut pair requires both projected fixed-contact cut inventories.")
        }
        if candidate.netID == other.netID, candidateName == otherName,
           candidate.x == other.x, candidate.y == other.y,
           candidate.lowerLayer == other.lowerLayer, candidate.upperLayer == other.upperLayer {
            return true
        }
        guard candidateSource.cutLayer == otherSource.cutLayer else { return true }
        for first in candidateShapes.indices {
            try budget.extend(1); try budget.charge(1)
            guard candidateShapes[first].layer == candidateSource.cutLayer else { continue }
            for second in otherShapes.indices {
                try budget.extend(1); try budget.charge(1)
                guard otherShapes[second].layer == otherSource.cutLayer else { continue }
                let a = candidateShapes[first], b = otherShapes[second]
                let n = a.points.count - (a.points.first == a.points.last ? 1 : 0)
                let m = b.points.count - (b.points.first == b.points.last ? 1 : 0)
                let pairs = n.multipliedReportingOverflow(by: m)
                let vertices = n.addingReportingOverflow(m)
                let work = pairs.partialValue.addingReportingOverflow(vertices.partialValue)
                guard !pairs.overflow, !vertices.overflow, !work.overflow else {
                    throw PhysicalDesignTechnologyError.invalid("Cut pair vertex work exceeds the index range.")
                }
                try budget.extend(work.partialValue); try budget.charge(work.partialValue)
                if try !PhysicalDesignFixedCutSeparation.separated(a, from: b,
                    minimum: cutSpacings[candidateSource.cutLayer] ?? 0) { return false }
            }
        }
        return true
    }
}
