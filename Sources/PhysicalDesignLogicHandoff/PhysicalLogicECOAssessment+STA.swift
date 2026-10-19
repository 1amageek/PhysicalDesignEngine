import LogicEngineRuntime
import LogicKernelCore
import LogicProof
import STAEngine
import TimingCore

extension PhysicalLogicECOAssessment {
    /// Checks the exact candidate and normal-power premises before any STA response.
    public func requirePreparedSTABinding(to prepared: PreparedSTAExecution,
                                         limits: PhysicalLogicHandoffLimits,
                                         context: inout LogicKernelContext) throws(PhysicalLogicSTABindingError) {
        do {
            try context.checkpoint()
            if Task.isCancelled { throw PhysicalLogicSTABindingError.sta(.cancelled) }
            guard case .equivalent(let proof) = verdict else {
                throw PhysicalLogicHandoffError.logicalMismatch("STA binding requires equivalent candidate functional evidence")
            }
            try proof.requireBinding(to: problem)
            guard let scope = baseline.request.operatingProcessScope else {
                throw PhysicalLogicHandoffError.unsupported("Source-only functional conditions do not establish a timing corner")
            }
            guard prepared.request.requireStrictSourceEvidence,
                  prepared.effectiveConfiguration.requireStrictSourceEvidence else {
                throw PhysicalLogicHandoffError.unsupported("STA binding requires strict source evidence")
            }
            let bytes = try PhysicalLogicSTATopology.workspaceBytes(self, limits: limits, context: &context)
            try requireProcessBinding(prepared, scope: scope, context: &context)
            let operating = try baseline.qualifyOperatingConditions(mapped, context: &context)
            try requireSupplyBinding(operating.receipt, prepared: prepared, context: &context)
            let reservation = try context.reserveStorage(byteCount: bytes)
            do {
                let expected = try PhysicalLogicSTATopology.build(self, context: &context)
                try prepared.requireDesignBinding(to: expected)
            } catch {
                try context.releaseStorage(reservation)
                throw error
            }
            try context.releaseStorage(reservation)
            try context.checkpoint()
            if Task.isCancelled { throw PhysicalLogicSTABindingError.sta(.cancelled) }
        } catch let error as PhysicalLogicSTABindingError { throw error }
        catch let error as PhysicalLogicHandoffError { throw .handoff(error) }
        catch let error as LogicKernelError { throw .kernel(error) }
        catch let error as LogicOperatingConditionError { throw .operatingConditions(error) }
        catch let error as STADesignBindingError { throw .design(error) }
        catch let error as STAExecutionError { throw .sta(error) }
        catch { throw .projection(error) }
    }

    /// Checks one signal candidate and its explicit normal-power premises against strict STA evidence.
    public func requireSTABinding(to prepared: PreparedSTAExecution, result: STAExecutionResult,
                                  validator: any STASourceEvidenceValidating,
                                  limits: PhysicalLogicHandoffLimits, context: inout LogicKernelContext,
                                  isolation: isolated (any Actor)? = #isolation)
        async throws(PhysicalLogicSTABindingError) {
        do {
            try requirePreparedSTABinding(to: prepared, limits: limits, context: &context)
            try await validator.validateSourceEvidence(result, against: prepared)
            try context.checkpoint()
            if Task.isCancelled { throw PhysicalLogicSTABindingError.sta(.cancelled) }
        } catch let error as PhysicalLogicSTABindingError { throw error }
        catch let error as LogicKernelError { throw .kernel(error) }
        catch let error as STAExecutionError { throw .sta(error) }
        catch { throw .projection(error) }
    }

    private func requireProcessBinding(_ prepared: borrowing PreparedSTAExecution,
                                       scope: borrowing LogicOperatingProcessScope,
                                       context: inout LogicKernelContext) throws {
        let selection = prepared.processSelection
        try context.charge(.workUnits)
        guard selection.manifest == scope.pdkManifest.reference,
              try same(selection.processID, scope.processID, context: &context),
              try same(selection.pdkVersion, scope.pdkVersion, context: &context),
              prepared.request.characterizationPolicy == .requireObservedConditions,
              prepared.effectiveConfiguration.characterizationPolicy == .requireObservedConditions,
              selection.corners.count == scope.cornerIDs.count,
              selection.librariesByCorner.count == scope.cornerIDs.count,
              prepared.effectiveConfiguration.cornerIDs.count == scope.cornerIDs.count,
              prepared.effectiveConfiguration.characterizationBindings.count == scope.characterizationBindings.count else {
            throw PhysicalLogicHandoffError.logicalMismatch("STA process, source or corner scope differs from the checked baseline")
        }
        for corner in scope.cornerIDs {
            var count = 0
            for actual in prepared.effectiveConfiguration.cornerIDs {
                if try same(corner, actual, context: &context) { count += 1 }
            }
            try charge(corner, context: &context)
            guard count == 1, selection.librariesByCorner[corner] == baseline.request.library.reference else {
                throw PhysicalLogicHandoffError.logicalMismatch("STA requires the exact baseline library in every declared corner")
            }
        }
        for expected in scope.characterizationBindings {
            var count = 0
            for actual in prepared.effectiveConfiguration.characterizationBindings {
                if try same(actual.cornerID, expected.cornerID, context: &context) {
                    try charge(actual.conditionName, context: &context)
                    try charge(expected.conditionName, context: &context)
                    guard actual == expected else {
                        throw PhysicalLogicHandoffError.logicalMismatch("STA source operating-condition selection differs")
                    }
                    count += 1
                }
            }
            guard count == 1 else { throw PhysicalLogicHandoffError.logicalMismatch("STA source condition coverage differs") }
        }
    }

    private func requireSupplyBinding(_ receipt: borrowing LogicOperatingConditionReceipt,
                                      prepared: borrowing PreparedSTAExecution,
                                      context: inout LogicKernelContext) throws {
        let corners = prepared.effectiveConfiguration.cornerIDs
        let assumptions = prepared.effectiveConfiguration.operatingSupplyAssumptions
        let expectedCount = candidate.cells.count.multipliedReportingOverflow(by: corners.count)
        guard !expectedCount.overflow, receipt.records.count == expectedCount.partialValue else {
            throw PhysicalLogicHandoffError.logicalMismatch("Candidate operating-condition coverage differs")
        }
        var pgCount = 0
        // Iterate the admitted mapped graph, not the baseline receipt's instance list.
        try mapped.withTables { _, instances, _, _, _, _ in
            for index in instances.indices {
                let instance = instances[index]
                let cell = try mapped.library.cell(at: instance.cell)
                try context.charge(.workUnits)
                guard let physical = correspondence.instanceIDs[instance.id] else {
                    throw PhysicalLogicHandoffError.invalidMapping("Missing candidate instance identity")
                }
                for corner in corners {
                    var match: LogicResolvedOperatingCondition?
                    for record in receipt.records {
                        try context.charge(.workUnits)
                        if record.instanceID == instance.id, let actualCorner = record.cornerID,
                           try same(actualCorner, corner, context: &context) {
                            guard match == nil else { throw PhysicalLogicHandoffError.logicalMismatch("Duplicate candidate source condition") }
                            match = record
                        }
                    }
                    guard let record = match, record.cellID == cell.id,
                          try same(record.cellName, cell.name, context: &context),
                          record.library == baseline.request.library.reference else {
                        throw PhysicalLogicHandoffError.logicalMismatch("Candidate source-cell or explicit corner identity differs")
                    }
                    let total = pgCount.addingReportingOverflow(record.normalPower.pgValues.count)
                    guard !total.overflow else { throw PhysicalLogicHandoffError.resourceLimit("Supply coverage count overflows") }
                    pgCount = total.partialValue
                    for pg in record.normalPower.pgValues {
                        var matches = 0
                        for actual in assumptions {
                            if try same(actual.instance, physical, context: &context),
                               try same(actual.cornerID, corner, context: &context),
                               try same(actual.pin, pg.condition.pin, context: &context) {
                                guard actual.library == record.library,
                                      try same(actual.cell, record.cellName, context: &context),
                                      try same(actual.sourcePGType, pg.condition.sourcePGType, context: &context),
                                      actual.value == (pg.condition.value ? .one : .zero) else {
                                    throw PhysicalLogicHandoffError.logicalMismatch("STA operating supply premise differs from functional admission")
                                }
                                matches += 1
                            }
                        }
                        guard matches == 1 else { throw PhysicalLogicHandoffError.logicalMismatch("STA supply coverage is missing or duplicated") }
                    }
                }
            }
        }
        guard pgCount == assumptions.count else {
            throw PhysicalLogicHandoffError.logicalMismatch("STA contains foreign operating supply premises")
        }
    }

    private func same(_ lhs: borrowing String, _ rhs: borrowing String,
                      context: inout LogicKernelContext) throws(LogicKernelError) -> Bool {
        try charge(lhs, context: &context); try charge(rhs, context: &context)
        return lhs == rhs
    }

    private func charge(_ value: borrowing String, context: inout LogicKernelContext) throws(LogicKernelError) {
        try context.charge(.workUnits, amount: UInt64(value.utf8.count) + 1)
    }
}
