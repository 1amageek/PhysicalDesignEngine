struct PhysicalDesignPlacementAllocation: Sendable {
    let snapshot: PhysicalDesignSnapshot
    let candidateChecks: Int
    let candidateCeiling: Int
    let structuralCeiling: Int
    let blockageConflictCount: Int
}
