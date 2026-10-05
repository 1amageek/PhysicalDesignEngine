import CoreSpice
import PEXNative

public struct PhysicalDesignClockNumerics: Sendable, Codable {
    public var stopTimeSeconds: Double
    public var maximumTimeStepSeconds: Double
    public var minimumTimeStepSeconds: Double
    public var relativeTolerance: Double
    public var voltageTolerance: Double
    public var currentTolerance: Double
    public var lteTolerance: Double
    public var maximumNewtonIterationsPerSolve: Int
    public var maximumStepReductions: Int
    public var maximumRefinements: Int
    public var crossingAgreementSeconds: Double
    /// Positive maximum mesh span in the source snapshot's `unitsPerMicron` scale.
    /// Conductor projection converts it to the capture grid before PEX extraction.
    public var maximumCellSpanDBU: Int32
    public var maximumInputBytes: Int
    public var maximumProjectionRecords: Int
    public var maximumGeometryProbes: Int
    public var extraction: NativePEXCalculationLimits
    public var electrodes: NativePEXElectrodeLimits
    public var transient: TransientExecutionLimits
    public init(stopTimeSeconds: Double, maximumTimeStepSeconds: Double, minimumTimeStepSeconds: Double,
                relativeTolerance: Double, voltageTolerance: Double, currentTolerance: Double, lteTolerance: Double,
                maximumNewtonIterationsPerSolve: Int, maximumStepReductions: Int, maximumRefinements: Int,
                crossingAgreementSeconds: Double, maximumCellSpanDBU: Int32, maximumInputBytes: Int,
                maximumProjectionRecords: Int, maximumGeometryProbes: Int, extraction: NativePEXCalculationLimits,
                electrodes: NativePEXElectrodeLimits, transient: TransientExecutionLimits) {
        self.stopTimeSeconds = stopTimeSeconds; self.maximumTimeStepSeconds = maximumTimeStepSeconds; self.minimumTimeStepSeconds = minimumTimeStepSeconds
        self.relativeTolerance = relativeTolerance; self.voltageTolerance = voltageTolerance; self.currentTolerance = currentTolerance; self.lteTolerance = lteTolerance
        self.maximumNewtonIterationsPerSolve = maximumNewtonIterationsPerSolve; self.maximumStepReductions = maximumStepReductions; self.maximumRefinements = maximumRefinements
        self.crossingAgreementSeconds = crossingAgreementSeconds; self.maximumCellSpanDBU = maximumCellSpanDBU; self.maximumInputBytes = maximumInputBytes
        self.maximumProjectionRecords = maximumProjectionRecords; self.maximumGeometryProbes = maximumGeometryProbes
        self.extraction = extraction; self.electrodes = electrodes; self.transient = transient
    }
    public func validate() throws {
        guard [stopTimeSeconds, maximumTimeStepSeconds, minimumTimeStepSeconds, relativeTolerance, voltageTolerance,
               currentTolerance, lteTolerance, crossingAgreementSeconds].allSatisfy({ $0.isFinite && $0 > 0 }),
              minimumTimeStepSeconds <= maximumTimeStepSeconds, maximumTimeStepSeconds <= stopTimeSeconds,
              maximumNewtonIterationsPerSolve > 0, maximumStepReductions >= 0, maximumRefinements > 0,
              maximumCellSpanDBU > 0, maximumInputBytes > 0, maximumProjectionRecords > 0, maximumGeometryProbes > 0 else {
            throw PhysicalDesignClockTimingModelError.invalidModel("numerical limits")
        }
        try transient.validate()
    }
}
