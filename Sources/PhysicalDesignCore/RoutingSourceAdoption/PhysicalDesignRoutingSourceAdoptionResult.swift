/// Only the checked adopter constructs this value; lineage transport is not a substitute.
public struct PhysicalDesignRoutingSourceAdoptionResult: Sendable {
    public let snapshot: PhysicalDesignSnapshot
    public let lineage: PhysicalDesignRoutingSourceAdoptionLineage

    init(snapshot: PhysicalDesignSnapshot, lineage: PhysicalDesignRoutingSourceAdoptionLineage) {
        self.snapshot = snapshot; self.lineage = lineage
    }
}
