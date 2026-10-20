import CoreSpice
import CoreSpiceIO
import LogicKernelCore
import STAEngine

extension PhysicalLogicECOAssessment {
    /// Builds the actual complete circuit and checks all independent and endogenous source joins.
    // FIXME(INCOMPLETE_IMPLEMENTATION): The controlled whole-candidate join is
    // implemented but remains unqualified until focused actual-SDK source,
    // resource/lifecycle tests and the one scoped review pass.
    public func certifyWholeCandidateFlow(preparedSTA: PreparedSTAExecution,
        request: PhysicalLogicWholeCandidateFlowRequest, limits: PhysicalLogicWholeCandidateFlowLimits,
        context: inout LogicKernelContext, resources: any SPICESourceResourceAccounting,
        cancellation: CancellationToken, isolation: isolated (any Actor)? = #isolation)
        async throws(PhysicalLogicWholeCandidateFlowFailure) -> PhysicalLogicWholeCandidateFlow {
        do {
            let control = try PhysicalLogicWholeCandidateControl.make(resources: resources, cancellation: cancellation, limits: limits)
            try control.check()
            guard limits.maximumSourceBytes > 0, limits.maximumSPEFBytes > 0,
                  limits.maximumComposedBytes > 0, limits.maximumJoinBytes > 0,
                  limits.maximumAssociations > 0,
                  request.source.root.binding.reference.byteCount <= limits.maximumSourceBytes,
                  request.spefReference.byteCount <= limits.maximumSPEFBytes,
                  request.source.catalog.count <= limits.maximumAssociations,
                  request.source.routes.count <= limits.maximumAssociations,
                  request.sourceBindings.count <= limits.maximumAssociations,
                  request.cellInstances.count <= limits.maximumAssociations,
                  request.pinNodes.count <= limits.maximumAssociations else {
                throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Invalid phase ceilings or input length")
            }
            do { try requirePreparedSTABinding(to: preparedSTA, limits: limits.handoff, context: &context) }
            catch { throw PhysicalLogicWholeCandidateFlowFailure.lower(phase: .candidate, cause: error) }
            try PhysicalLogicWholeCandidateSourceValidation.validateMappings(self, request: request, control: control)
            try PhysicalLogicWholeCandidateJoin.validateTime(request, control: control)
            let timing: STAConservativeSourceContext
            do { timing = try NativeSTAEngine().validateInitialSourceContext(request.timingContext, against: preparedSTA) }
            catch { throw PhysicalLogicWholeCandidateFlowFailure.lower(phase: .family, cause: error) }
            try control.check()
            guard try control.same(request.pexCorner.value, timing.record.cornerID) else {
                throw PhysicalLogicWholeCandidateFlowFailure.parasitics("PEX execution label differs from the revalidated Timing corner")
            }
            let slices = try PhysicalLogicWholeCandidateJoin.slices(timing, request: request, control: control)
            for index in timing.record.sources.indices {
                _ = try PhysicalLogicWholeCandidateJoin.pin(at: index, assessment: self, timing: timing, request: request, control: control)
            }
            let source = try await PhysicalLogicWholeCandidateComposition.prepare(assessment: self,
                preparedSTA: preparedSTA, request: request, control: control)
            try control.check()
            try PhysicalLogicWholeCandidateSourceValidation.validate(self, preparedSTA: preparedSTA,
                request: request, source: source, control: control)
            let circuit = try await Self.prepareNative(source: source, request: request, control: control)
            let result: PhysicalLogicWholeCandidateFlow
            do {
                try control.check()
                let pairLease = try control.slots(NativePrescribedVoltageFlowVoltagePair.self, count: slices.count)
                defer { withExtendedLifetime(pairLease) {} }
                let pairs = try PhysicalLogicWholeCandidateJoin.pairs(assessment: self, timing: timing,
                    request: request, source: source, control: control)
                try PhysicalLogicWholeCandidateJoin.actualSources(circuit, source: source, timing: timing, slices: slices,
                    request: request, pairs: pairs.span, control: control)
                let flow = try await circuit.certifyPrescribedVoltageFlow(request: request.native.flow,
                    capture: request.native.capture, range: request.native.range,
                    limits: limits.flow, cancellation: cancellation)
                try control.check()
                let observations = try flow.observeVoltages(pairs: pairs.span, limits: limits.observations, cancellation: cancellation)
                try control.check()
                try PhysicalLogicWholeCandidateJoin.validate(observations: observations, timing: timing,
                    slices: slices, source: source, request: request, control: control)
                let storage = try control.reserve(PhysicalLogicWholeCandidateFlow.retainedByteCount, kind: .liveOwnedBytes)
                result = PhysicalLogicWholeCandidateFlow(assessment: self, preparedSTA: preparedSTA,
                    sourcePreparation: source, observations: observations, timingContext: timing,
                    jointSlices: slices, rail: request.rail, storage: storage)
            } catch {
                let primary = PhysicalLogicWholeCandidateControl.failure(error)
                do { try circuit.close() }
                catch { throw PhysicalLogicWholeCandidateFlowFailure.cleanup(primary: primary, secondary: error) }
                throw primary
            }
            // Closing is a publication prerequisite, including the actual lower pending-cleanup owner.
            do { try circuit.close() }
            catch { throw PhysicalLogicWholeCandidateFlowFailure.native(error) }
            try control.check()
            return result
        } catch let failure as PhysicalLogicWholeCandidateFlowFailure { throw failure }
        catch { throw PhysicalLogicWholeCandidateControl.failure(error) }
    }
    private static func prepareNative(source: PreparedSPICESimulation,
        request: PhysicalLogicWholeCandidateFlowRequest, control: PhysicalLogicWholeCandidateControl)
        async throws -> PreparedNativeCircuit {
        try control.check()
        let conditions = try source.configuration.options.operatingConditions()
        let preparer = NativeCircuitPreparer()
        if let runtime = request.native.osdi, let snapshot = request.native.constitutive {
            return try await preparer.prepare(ir: source.circuit, registry: .standard(), operatingConditions: conditions,
                limits: control.limits.native, numericalLimits: source.configuration.numericalLimits,
                resources: control, osdi: runtime, constitutive: snapshot, cancellation: control.cancellation)
        }
        guard request.native.osdi == nil, request.native.constitutive == nil else {
            throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Incomplete actual OSDI snapshot policy")
        }
        return try preparer.prepareNativeConstitutive(ir: source.circuit, registry: .standard(), operatingConditions: conditions,
            limits: control.limits.native, numericalLimits: source.configuration.numericalLimits,
            resources: control, cancellation: control.cancellation)
    }
}
