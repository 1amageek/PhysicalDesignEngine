import CoreSpice
import CoreSpiceIO
import PhysicalDesignCore
import STAEngine

/// Checks original root calls and every actual signal/PG terminal before Native preparation.
internal enum PhysicalLogicWholeCandidateSourceValidation {
    static func validateMappings(_ assessment: PhysicalLogicECOAssessment,
        request: PhysicalLogicWholeCandidateFlowRequest, control: PhysicalLogicWholeCandidateControl) throws {
        guard request.cellInstances.count == assessment.candidate.cells.count,
              request.pinNodes.count == assessment.candidate.pins.count else {
            throw PhysicalLogicWholeCandidateFlowFailure.candidate("Incomplete candidate correspondence")
        }
        for cell in assessment.candidate.cells {
            try control.check()
            guard let name = request.cellInstances[cell.id], !name.isEmpty else {
                throw PhysicalLogicWholeCandidateFlowFailure.candidate("Missing original cell correspondence")
            }
        }
        for (i, pin) in assessment.candidate.pins.enumerated() {
            try control.check()
            guard let name = request.pinNodes[pin.id], !name.isEmpty else {
                throw PhysicalLogicWholeCandidateFlowFailure.candidate("Missing original pin correspondence")
            }
            for j in 0..<i {
                try control.check()
                if let prior = request.pinNodes[assessment.candidate.pins[j].id], try control.symbol(name, prior) {
                    throw PhysicalLogicWholeCandidateFlowFailure.source("Distinct physical terminals were shorted")
                }
            }
        }
    }
    static func validate(_ assessment: PhysicalLogicECOAssessment, preparedSTA: PreparedSTAExecution,
        request: PhysicalLogicWholeCandidateFlowRequest, source: PreparedSPICESimulation,
        control: PhysicalLogicWholeCandidateControl) throws {
        let candidate = assessment.candidate, netlist = source.netlist
        guard request.cellInstances.count == candidate.cells.count,
              request.pinNodes.count == candidate.pins.count,
              candidate.cells.count <= control.limits.maximumAssociations,
              candidate.pins.count <= control.limits.maximumAssociations else {
            throw PhysicalLogicWholeCandidateFlowFailure.candidate("Incomplete candidate correspondence")
        }
        // The same SPEF bytes must have been consumed by the actual immutable STA preparation.
        guard preparedSTA.request.parasitics?.reference == request.spefReference else {
            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Prepared STA uses a different SPEF artifact")
        }
        let rail = request.rail
        guard rail.zeroNode == "0", rail.zeroVoltage == 0, rail.oneVoltage.isFinite,
              rail.oneVoltage > 0, !rail.sourceName.isEmpty, !rail.oneNode.isEmpty,
              rail.oneNode != "0" else {
            throw PhysicalLogicWholeCandidateFlowFailure.rail("Unsupported or invalid explicit grounded rail")
        }
        var characterized = 0
        for observation in preparedSTA.characterization {
            try control.check()
            if observation.selected, observation.cornerID == request.timingContext.cornerID {
                guard observation.voltage?.bitPattern == rail.oneVoltage.bitPattern,
                      observation.temperatureCelsius?.bitPattern == source.configuration.temperatureCelsius.bitPattern,
                      observation.source == request.timingContext.library else {
                    throw PhysicalLogicWholeCandidateFlowFailure.rail("Actual numeric Liberty conditions differ")
                }
                characterized += 1
            }
        }
        guard characterized > 0 else { throw PhysicalLogicWholeCandidateFlowFailure.rail("Missing observed numeric characterization") }
        var pgCount = 0
        for (cellIndex, cell) in candidate.cells.enumerated() {
            try control.check()
            guard let spiceName = request.cellInstances[cell.id] else {
                throw PhysicalLogicWholeCandidateFlowFailure.candidate("Missing original cell instance correspondence")
            }
            for prior in 0..<cellIndex {
                try control.check()
                if let priorName = request.cellInstances[candidate.cells[prior].id], try control.symbol(priorName, spiceName) {
                    throw PhysicalLogicWholeCandidateFlowFailure.candidate("Duplicated root cell instance")
                }
            }
            var call: ParsedComponent?
            for component in netlist.components {
                try control.check()
                if try control.symbol(component.name, spiceName) {
                    guard call == nil else { throw PhysicalLogicWholeCandidateFlowFailure.source("Duplicate root call") }
                    call = component
                }
            }
            guard let call, call.type == .subcircuitInstance,
                  let model = call.modelName, try control.symbol(model, cell.master) else {
                throw PhysicalLogicWholeCandidateFlowFailure.source("Actual cell master differs from the candidate correspondence")
            }
            var definition: ParsedSubcircuit?
            for item in netlist.subcircuits {
                try control.check()
                if try control.symbol(item.name, model) {
                    guard definition == nil else { throw PhysicalLogicWholeCandidateFlowFailure.source("Ambiguous original cell declaration") }
                    definition = item
                }
            }
            guard let definition, definition.ports.count == call.nodes.count else {
                throw PhysicalLogicWholeCandidateFlowFailure.source("Original cell port order is unavailable")
            }
            var matchedPins = 0
            for (index, port) in definition.ports.enumerated() {
                try control.text(port)
                var pin: PhysicalDesignSnapshot.Pin?
                for item in candidate.pins {
                    try control.check()
                    if item.cellID == cell.id, try control.symbol(item.name, port) {
                        guard pin == nil else { throw PhysicalLogicWholeCandidateFlowFailure.candidate("Ambiguous physical terminal") }
                        pin = item
                    }
                }
                if let pin {
                    guard let node = request.pinNodes[pin.id], try control.symbol(call.nodes[index].name, node) else {
                        throw PhysicalLogicWholeCandidateFlowFailure.source("Original signal terminal differs from the physical correspondence")
                    }
                    matchedPins += 1
                } else {
                    var matches = 0
                    for pg in preparedSTA.effectiveConfiguration.operatingSupplyAssumptions {
                        try control.check()
                        if pg.instance == cell.id, pg.cornerID == request.timingContext.cornerID,
                           try control.symbol(pg.pin, port) {
                            let expected = pg.value == .one ? rail.oneNode : rail.zeroNode
                            guard pg.cell == cell.master, try control.symbol(call.nodes[index].name, expected) else {
                                throw PhysicalLogicWholeCandidateFlowFailure.rail("Original PG/body terminal differs from its checked premise")
                            }
                            matches += 1; pgCount += 1
                        }
                    }
                    guard matches == 1 else { throw PhysicalLogicWholeCandidateFlowFailure.rail("Missing or ambiguous PG/body terminal") }
                }
            }
            var physicalPins = 0
            for pin in candidate.pins { try control.check(); if pin.cellID == cell.id { physicalPins += 1 } }
            guard matchedPins == physicalPins else { throw PhysicalLogicWholeCandidateFlowFailure.source("A physical signal pin was omitted") }
        }
        var expectedPG = 0
        for pg in preparedSTA.effectiveConfiguration.operatingSupplyAssumptions {
            try control.check(); if pg.cornerID == request.timingContext.cornerID { expectedPG += 1 }
        }
        guard pgCount == expectedPG else { throw PhysicalLogicWholeCandidateFlowFailure.rail("A PG/body premise was omitted") }
        for (i, pin) in candidate.pins.enumerated() {
            try control.check()
            guard pin.netID != nil, let node = request.pinNodes[pin.id], !node.isEmpty, node != "0" else {
                throw PhysicalLogicWholeCandidateFlowFailure.candidate("Missing physical signal node correspondence")
            }
            for j in 0..<i {
                try control.check()
                if let prior = request.pinNodes[candidate.pins[j].id], try control.symbol(prior, node) {
                    throw PhysicalLogicWholeCandidateFlowFailure.source("Distinct physical terminals were shorted")
                }
            }
            var found = false
            for actual in source.circuit.nodeNames.values {
                try control.check(); if try control.symbol(actual, node) { found = true }
            }
            guard found else {
                throw PhysicalLogicWholeCandidateFlowFailure.source("Physical signal node correspondence was lost in lowering")
            }
        }
        // Exactly the original cell calls, the composer call, one rail and the primary input sources.
        for component in netlist.components {
            try control.check()
            if component.type == .subcircuitInstance {
                var matches = try control.symbol(component.name, "XPEX_whole") ? 1 : 0
                for name in request.cellInstances.values { try control.check(); if try control.symbol(name, component.name) { matches += 1 } }
                guard matches == 1 else { throw PhysicalLogicWholeCandidateFlowFailure.source("Unassociated root subcircuit") }
            } else if component.type == .voltageSource {
                var matches = try control.symbol(component.name, rail.sourceName) ? 1 : 0
                for binding in request.sourceBindings {
                    try control.check()
                    if let name = binding.sourceDeviceName, try control.symbol(name, component.name) { matches += 1 }
                }
                guard matches == 1 else { throw PhysicalLogicWholeCandidateFlowFailure.source("Unassociated independent voltage source") }
            } else {
                throw PhysicalLogicWholeCandidateFlowFailure.source("Unexpected root contributor")
            }
        }
    }

    static func node(named name: String, in source: PreparedSPICESimulation,
        control: PhysicalLogicWholeCandidateControl) throws -> Node {
        if name == "0" { return .ground }
        var result: Node?
        for (node, actual) in source.circuit.nodeNames {
            try control.check()
            if try control.symbol(actual, name) {
                guard result == nil else { throw PhysicalLogicWholeCandidateFlowFailure.source("Ambiguous lowered node") }
                result = node
            }
        }
        guard let result else { throw PhysicalLogicWholeCandidateFlowFailure.source("A requested actual lowered node is missing") }
        return result
    }
}
