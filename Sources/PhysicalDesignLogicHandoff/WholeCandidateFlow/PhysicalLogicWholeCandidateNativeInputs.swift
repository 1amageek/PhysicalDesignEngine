import CoreSpice

/// Lower policy values and untrusted numerical proposals; no executable owner is accepted.
public struct PhysicalLogicWholeCandidateNativeInputs: Sendable {
    public let osdi: SPICEOSDIRuntimeInputs?
    public let constitutive: NativeConstitutivePreparationInputs?
    public let capture: OSDIConstitutiveCaptureInputs?
    public let range: OSDISmoothRangeCaptureInputs?
    public let flow: NativePrescribedVoltageFlowRequest
    public init(osdi: SPICEOSDIRuntimeInputs? = nil, constitutive: NativeConstitutivePreparationInputs? = nil,
        capture: OSDIConstitutiveCaptureInputs? = nil, range: OSDISmoothRangeCaptureInputs? = nil,
        flow: NativePrescribedVoltageFlowRequest) {
        self.osdi = osdi; self.constitutive = constitutive; self.capture = capture; self.range = range; self.flow = flow
    }
}
