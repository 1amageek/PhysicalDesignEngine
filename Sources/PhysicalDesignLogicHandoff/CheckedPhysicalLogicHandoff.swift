import LogicEngineRuntime
import PhysicalDesignCore

public struct CheckedPhysicalLogicHandoff: Sendable {
    public let synthesis: LogicVerifiedSynthesis
    public let snapshot: PhysicalDesignSnapshot
    public let correspondence: PhysicalLogicCorrespondence
    internal init(synthesis: LogicVerifiedSynthesis, snapshot: PhysicalDesignSnapshot,
                  correspondence: PhysicalLogicCorrespondence) {
        self.synthesis = synthesis; self.snapshot = snapshot; self.correspondence = correspondence
    }
}
