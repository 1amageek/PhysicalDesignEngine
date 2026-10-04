import PDKCore
import PEXCore
import TimingCore

public struct PhysicalDesignClockCharacterization: Sendable {
    public let model: PhysicalDesignClockTimingModel
    public let library: CharacterizedTimingLibrary
    public let technology: TechnologyIR
    public let corner: PEXCorner
    public let reference: PhysicalDesignClockTimingModelReference
    init(model: PhysicalDesignClockTimingModel, library: CharacterizedTimingLibrary, technology: TechnologyIR,
         corner: PEXCorner, reference: PhysicalDesignClockTimingModelReference) {
        self.model = model; self.library = library; self.technology = technology; self.corner = corner; self.reference = reference
    }
}
