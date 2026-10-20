import CoreSpice
import CoreSpiceIO
import PhysicalDesignCore
import STAEngine

/// Cross-domain inclusion only; all electrical and family bounds come from their actual owners.
internal enum PhysicalLogicWholeCandidateJoin {
    static func bounds(_ value: CompensatedEnclosure) throws -> ClosedRange<Double> {
        let pair = value.center.bounds
        let lower = value.radius == 0 ? pair.lower : (pair.lower - value.radius).nextDown
        let upper = value.radius == 0 ? pair.upper : (pair.upper + value.radius).nextUp
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            throw PhysicalLogicWholeCandidateFlowFailure.time("Nonfinite outward projection")
        }
        return lower...upper
    }
    static func contains(_ outer: ClosedRange<Double>, _ inner: ClosedRange<Double>) -> Bool {
        outer.lowerBound <= inner.lowerBound && inner.upperBound <= outer.upperBound
    }
    private static func containsPoint(_ outer: ClosedRange<Double>, _ value: CompensatedValue) -> Bool {
        // Normalized DD ordering against an exact binary64 endpoint needs no rounded sum.
        let above = value.high > outer.lowerBound || (value.high == outer.lowerBound && value.low >= 0)
        let below = value.high < outer.upperBound || (value.high == outer.upperBound && value.low <= 0)
        return above && below
    }
    static func binding(at index: Int, request: PhysicalLogicWholeCandidateFlowRequest,
        control: PhysicalLogicWholeCandidateControl) throws -> PhysicalLogicWholeCandidateSourceBinding {
        var found: PhysicalLogicWholeCandidateSourceBinding?
        for binding in request.sourceBindings {
            try control.check()
            if binding.sourceIndex == index {
                guard found == nil else { throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Duplicate canonical source") }
                found = binding
            }
        }
        guard let found else { throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Missing canonical source") }
        return found
    }
    static func validateTime(_ request: PhysicalLogicWholeCandidateFlowRequest,
        control: PhysicalLogicWholeCandidateControl) throws {
        try control.check()
        let t0 = try CompensatedEnclosure(center: request.native.flow.startTime)
        let h = try CompensatedEnclosure(center: request.native.flow.duration)
        let end = try t0.adding(h)
        let terminal: CompensatedValue
        if end.radius == 0 { terminal = end.center }
        else { terminal = try CompensatedValue(high: bounds(end).upperBound) }
        guard request.native.flow.duration.bounds.lower > 0,
              request.initialTimeSI.lowerBound.isFinite, request.initialTimeSI.upperBound.isFinite,
              request.windowSI.lowerBound.isFinite, request.windowSI.upperBound.isFinite,
              containsPoint(request.initialTimeSI, request.native.flow.startTime),
              containsPoint(request.windowSI, request.native.flow.startTime), containsPoint(request.windowSI, terminal) else {
            throw PhysicalLogicWholeCandidateFlowFailure.time("Timing hull omits the represented DD slab")
        }
    }
    static func slices(_ timing: STAConservativeSourceContext,
        request: PhysicalLogicWholeCandidateFlowRequest, control: PhysicalLogicWholeCandidateControl)
        throws -> SPICEAccountedCollection<STAConservativeSourceJointSlice> {
        let count = timing.record.sources.count
        guard count > 0, count <= control.limits.maximumAssociations, request.sourceBindings.count == count else {
            throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: -1, reason: "Incomplete canonical source inventory")
        }
        var result = SPICEAccountedCollection<STAConservativeSourceJointSlice>(storageKind: .liveOwnedBytes)
        try result.reserveCapacity(count, resources: control.joinAccounting)
        for index in 0..<count {
            try control.check()
            _ = try binding(at: index, request: request, control: control)
            let slice = try timing.jointSlice(sourceAt: index, initialTime: request.initialTimeSI, over: request.windowSI)
            try control.check()
            try result.append(slice, resources: control.joinAccounting)
        }
        return result
    }
    static func pin(at index: Int, assessment: PhysicalLogicECOAssessment,
        timing: STAConservativeSourceContext, request: PhysicalLogicWholeCandidateFlowRequest,
        control: PhysicalLogicWholeCandidateControl) throws -> PhysicalDesignSnapshot.Pin {
        let association = try binding(at: index, request: request, control: control)
        var found: PhysicalDesignSnapshot.Pin?
        for pin in assessment.candidate.pins {
            try control.check()
            if pin.id == association.physicalPinID {
                guard found == nil else { throw PhysicalLogicWholeCandidateFlowFailure.candidate("Duplicate physical source endpoint") }
                found = pin
            }
        }
        guard let pin = found, let net = pin.netID, let nodeName = request.pinNodes[pin.id],
              timing.record.sources[index].authority.endpoint.ownerNet == net,
              try control.same(timing.record.sources[index].authority.endpoint.name, nodeName) else {
            throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Actual endpoint/owner net differs")
        }
        let source = timing.record.sources[index]
        switch source.origin {
        case .primaryPort:
            guard source.authority.sourceIsPort, pin.cellID == nil,
                  try control.symbol(pin.direction, "input"), association.sourceDeviceName != nil else {
                throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Independent input is not an actual primary port")
            }
        case .prescribedCellOutput:
            guard !source.authority.sourceIsPort, pin.cellID != nil,
                  try control.symbol(pin.direction, "output"), association.sourceDeviceName == nil else {
                throw PhysicalLogicWholeCandidateFlowFailure.internalOutput(sourceIndex: index, reason: "Endogenous output cannot be prescribed")
            }
        }
        return pin
    }
    static func pairs(assessment: PhysicalLogicECOAssessment, timing: STAConservativeSourceContext,
        request: PhysicalLogicWholeCandidateFlowRequest, source: PreparedSPICESimulation,
        control: PhysicalLogicWholeCandidateControl) throws -> [NativePrescribedVoltageFlowVoltagePair] {
        let count = timing.record.sources.count
        // Caller retains this lease over construction and the lower observation call.
        var pairs = [NativePrescribedVoltageFlowVoltagePair](repeating: .init(positive: .ground, reference: .ground), count: count)
        for index in 0..<count {
            try control.check()
            let pin = try pin(at: index, assessment: assessment, timing: timing, request: request, control: control)
            guard let name = request.pinNodes[pin.id] else { throw PhysicalLogicWholeCandidateFlowFailure.candidate("Missing observation node") }
            let node = try PhysicalLogicWholeCandidateSourceValidation.node(named: name, in: source, control: control)
            pairs[index] = .init(positive: node, reference: .ground)
        }
        return pairs
    }
    static func actualSources(_ circuit: borrowing PreparedNativeCircuit, source: PreparedSPICESimulation,
        timing: STAConservativeSourceContext, slices: SPICEAccountedCollection<STAConservativeSourceJointSlice>,
        request: PhysicalLogicWholeCandidateFlowRequest,
        pairs: borrowing Span<NativePrescribedVoltageFlowVoltagePair>,
        connections: PhysicalLogicWholeCandidateIdealConnections?, control: PhysicalLogicWholeCandidateControl) throws {
        let one = try PhysicalLogicWholeCandidateSourceValidation.node(named: request.rail.oneNode, in: source, control: control)
        do {
            try circuit.withIndependentVoltageSources(cancellation: control.cancellation) { view in
                var rails = 0, primaryCount = 0, connectionCount = 0
                for fact in view.sources {
                    try control.check()
                    if let connections, try connections.validate(fact, control: control) {
                        connectionCount += 1
                    } else if try control.symbol(fact.instance.name, request.rail.sourceName) {
                        guard fact.positiveNode == one, fact.negativeNode == .ground,
                              fact.dcVoltage.bitPattern == request.rail.oneVoltage.bitPattern,
                              case .dc(let value) = fact.waveform, value.bitPattern == request.rail.oneVoltage.bitPattern else {
                            throw PhysicalLogicWholeCandidateFlowFailure.rail("Actual bound rail law differs")
                        }
                        rails += 1
                    } else {
                        var matches = 0
                        for index in timing.record.sources.indices {
                            try control.check()
                            let binding = try binding(at: index, request: request, control: control)
                            if let name = binding.sourceDeviceName, try control.symbol(fact.instance.name, name) {
                                guard fact.positiveNode == pairs[index].positive, fact.negativeNode == pairs[index].reference else {
                                    throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Actual signed source incidence differs")
                                }
                                var proposals = 0
                                for law in request.native.flow.sources {
                                    try control.check()
                                    guard view.preparation.plan.ir.instances.indices.contains(law.deviceIndex) else {
                                        throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Invalid source device index")
                                    }
                                    if try control.symbol(view.preparation.plan.ir.instances[law.deviceIndex].name, fact.instance.name) {
                                        let slice = slices[index]
                                        guard law.zeroVoltage.bitPattern == request.rail.zeroVoltage.bitPattern,
                                              law.oneVoltage.bitPattern == request.rail.oneVoltage.bitPattern,
                                              contains(law.initialNormalized, slice.initialValue),
                                              contains(law.normalized, slice.windowValue),
                                              contains(law.normalizedDerivativePerSecond, slice.almostEverywhereSlope) else {
                                            throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Complete initial/window/SI-rate family is not covered")
                                        }
                                        proposals += 1
                                    }
                                }
                                guard proposals == 1 else { throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Missing or duplicate actual source proposal") }
                                matches += 1
                            }
                        }
                        guard matches == 1 else { throw PhysicalLogicWholeCandidateFlowFailure.source("A bound voltage source is not a primary input or the rail") }
                        primaryCount += 1
                    }
                }
                var expected = 0
                for binding in request.sourceBindings { try control.check(); if binding.sourceDeviceName != nil { expected += 1 } }
                guard rails == 1, primaryCount == expected, connectionCount == (connections?.rows.count ?? 0),
                      request.native.flow.sources.count == expected else {
                    throw PhysicalLogicWholeCandidateFlowFailure.source("Incomplete actual independent-source inventory")
                }
            }
        } catch let issue as NativeVoltageSourceInspectionFailure {
            // Preserve our own callback classification at this exact borrow;
            // all other Native cases and foreign causes retain their original value.
            if case .callback(let cause) = issue,
               let local = cause as? PhysicalLogicWholeCandidateFlowFailure {
                throw local
            }
            throw issue
        }
    }
    static func validate(observations: NativePrescribedVoltageFlowVoltageObservations,
        timing: STAConservativeSourceContext, slices: SPICEAccountedCollection<STAConservativeSourceJointSlice>,
        source: PreparedSPICESimulation, request: PhysicalLogicWholeCandidateFlowRequest,
        connections: PhysicalLogicWholeCandidateIdealConnections?, control: PhysicalLogicWholeCandidateControl) throws {
        guard observations.count == timing.record.sources.count, slices.count == observations.count else {
            throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: -1, reason: "Incomplete same-owner observations")
        }
        let expectedConditions = try source.configuration.options.operatingConditions()
        try observations.flow.withScope { scope in
            try control.check()
            guard scope.startTime == request.native.flow.startTime, scope.duration == request.native.flow.duration,
                  scope.preparation.plan.ir.instances.count == source.circuit.instances.count,
                  scope.preparation.plan.ir.nodes.count == source.circuit.nodes.count,
                  scope.preparation.operatingConditions == expectedConditions else {
                throw PhysicalLogicWholeCandidateFlowFailure.source("Actual retained Flow scope differs")
            }
            let actualStart = try CompensatedValue(high: scope.initialContext.timeHigh, low: scope.initialContext.timeLow)
            let actualEnd = try CompensatedValue(high: scope.windowUpperContext.timeHigh, low: scope.windowUpperContext.timeLow)
            guard containsPoint(request.initialTimeSI, actualStart), containsPoint(request.windowSI, actualStart),
                  containsPoint(request.windowSI, actualEnd) else {
                throw PhysicalLogicWholeCandidateFlowFailure.time("Timing hull omits the actual retained Native endpoint context")
            }
            var selectedCount = 0
            for index in timing.record.sources.indices {
                try control.check()
                let binding = try binding(at: index, request: request, control: control), slice = slices[index]
                switch timing.record.sources[index].origin {
                case .primaryPort:
                    guard let name = binding.sourceDeviceName else {
                        throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Missing independent source")
                    }
                    var matches = 0
                    for selected in scope.sources {
                        try control.check()
                        if try control.symbol(selected.fact.instance.name, name) {
                            let actual = try observations.observation(at: index)
                            let law = selected.assumptions
                            guard selected.fact.positiveNode == actual.pair.positive,
                                  selected.fact.negativeNode == actual.pair.reference,
                                  law.zeroVoltage.bitPattern == request.rail.zeroVoltage.bitPattern,
                                  law.oneVoltage.bitPattern == request.rail.oneVoltage.bitPattern,
                                  contains(law.initialNormalized, slice.initialValue),
                                  contains(law.normalized, slice.windowValue),
                                  contains(law.normalizedDerivativePerSecond, slice.almostEverywhereSlope) else {
                                throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Complete initial/window/SI-rate family is not covered")
                            }
                            matches += 1
                        }
                    }
                    guard matches == 1 else { throw PhysicalLogicWholeCandidateFlowFailure.family(sourceIndex: index, reason: "Source absent from actual Flow") }
                    selectedCount += 1
                case .prescribedCellOutput:
                    let actual = try observations.observation(at: index)
                    let scale = try CompensatedEnclosure(center: CompensatedValue(high: request.rail.oneVoltage))
                    let initial = request.rail.oneVoltage == 1 ? actual.initialVoltage : try actual.initialVoltage.divided(by: scale)
                    let window = request.rail.oneVoltage == 1 ? actual.windowVoltage : try actual.windowVoltage.divided(by: scale)
                    let rate = request.rail.oneVoltage == 1 ? actual.almostEverywhereRate : try actual.almostEverywhereRate.divided(by: scale)
                    guard contains(slice.initialValue, try bounds(initial)), contains(slice.windowValue, try bounds(window)),
                          contains(slice.almostEverywhereSlope, try bounds(rate)) else {
                        throw PhysicalLogicWholeCandidateFlowFailure.internalOutput(sourceIndex: index, reason: "Actual endogenous response is outside a Timing boundary premise")
                    }
                }
            }
            let connectionCount = try connections?.validate(scope.sources, control: control) ?? 0
            guard selectedCount + connectionCount == scope.sources.count else { throw PhysicalLogicWholeCandidateFlowFailure.source("Flow prescribes an unassociated source") }
        }
    }
}
