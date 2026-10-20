import CoreSpice
import CoreSpiceIO
import STAEngine

/// A complete conditional join, constructed only by the actual assessed-candidate producer.
public final class PhysicalLogicWholeCandidateFlow: Sendable {
    private let payload: Payload
    public var assessment: PhysicalLogicECOAssessment { payload.assessment }
    public var preparedSTA: PreparedSTAExecution { payload.preparedSTA }
    public var sourcePreparation: PreparedSPICESimulation { payload.sourcePreparation }
    public var observations: NativePrescribedVoltageFlowVoltageObservations { payload.observations }
    public var timingContext: STAConservativeSourceContext { payload.timingContext }
    public var jointSlices: SPICEAccountedCollection<STAConservativeSourceJointSlice> { payload.jointSlices }
    public var rail: PhysicalLogicWholeCandidateRail { payload.rail }
    internal static var retainedByteCount: UInt64 { UInt64(MemoryLayout<Payload>.stride) }
    internal init(assessment: PhysicalLogicECOAssessment, preparedSTA: PreparedSTAExecution,
        sourcePreparation: PreparedSPICESimulation, observations: NativePrescribedVoltageFlowVoltageObservations,
        timingContext: STAConservativeSourceContext, jointSlices: SPICEAccountedCollection<STAConservativeSourceJointSlice>,
        rail: PhysicalLogicWholeCandidateRail, storage: SPICESourceStorageReservation) {
        payload = Payload(assessment: assessment, preparedSTA: preparedSTA, sourcePreparation: sourcePreparation,
            observations: observations, timingContext: timingContext, jointSlices: jointSlices, rail: rail, storage: storage)
    }
    private struct Payload: Sendable {
        let assessment: PhysicalLogicECOAssessment
        let preparedSTA: PreparedSTAExecution
        let sourcePreparation: PreparedSPICESimulation
        let observations: NativePrescribedVoltageFlowVoltageObservations
        let timingContext: STAConservativeSourceContext
        let jointSlices: SPICEAccountedCollection<STAConservativeSourceJointSlice>
        let rail: PhysicalLogicWholeCandidateRail
        let storage: SPICESourceStorageReservation
    }
}
