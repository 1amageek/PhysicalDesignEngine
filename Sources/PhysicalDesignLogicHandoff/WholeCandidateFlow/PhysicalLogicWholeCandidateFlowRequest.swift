import Foundation
import CircuiteFoundation
import CoreSpiceIO
import PEXCore
import STAEngine

/// Caller values are proposals; only the direct actual producer can create the result.
public struct PhysicalLogicWholeCandidateFlowRequest: Sendable {
    public let source: SPICESimulationPreparationRequest
    public let spefReference: ArtifactReference
    public let spefBytes: Data
    public let pexCorner: PEXCornerID
    public let cellInstances: [String: String]
    public let pinNodes: [String: String]
    public let rail: PhysicalLogicWholeCandidateRail
    public let sourceBindings: [PhysicalLogicWholeCandidateSourceBinding]
    public let timingContext: STAConservativeSourceContextRecord
    public let initialTimeSI: ClosedRange<Double>
    public let windowSI: ClosedRange<Double>
    public let native: PhysicalLogicWholeCandidateNativeInputs
    public init(source: SPICESimulationPreparationRequest, spefReference: ArtifactReference, spefBytes: Data,
        pexCorner: PEXCornerID, cellInstances: [String: String], pinNodes: [String: String],
        rail: PhysicalLogicWholeCandidateRail, sourceBindings: [PhysicalLogicWholeCandidateSourceBinding],
        timingContext: STAConservativeSourceContextRecord, initialTimeSI: ClosedRange<Double>,
        windowSI: ClosedRange<Double>, native: PhysicalLogicWholeCandidateNativeInputs) {
        self.source = source; self.spefReference = spefReference; self.spefBytes = spefBytes; self.pexCorner = pexCorner
        self.cellInstances = cellInstances; self.pinNodes = pinNodes; self.rail = rail; self.sourceBindings = sourceBindings
        self.timingContext = timingContext; self.initialTimeSI = initialTimeSI; self.windowSI = windowSI; self.native = native
    }
}
