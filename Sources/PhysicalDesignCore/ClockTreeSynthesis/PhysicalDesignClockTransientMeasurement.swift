import CoreSpice
import PEXNative
import TimingCore

/// Owns request-wide transient allowances and threshold observation, not a second solver.
struct PhysicalDesignClockTransientMeasurement {
    struct Observation: Sendable, Hashable, Codable {
        let pinID: String
        let arrivalSeconds: Double
        let slewSeconds: Double
        let waveform: [PhysicalDesignClockTimingModel.Point]
    }
    struct Result {
        let loadFarads: Double
        let observations: [String: Observation]
        let statistics: [TransientExecutionStatistics]
        let crossingDifferenceSeconds: Double
        let finalMaximumStepSeconds: Double
    }
    var remaining: TransientExecutionLimits
    init(limits: TransientExecutionLimits) { remaining = limits }

    func load(netID: String, projection: PhysicalDesignClockConductorProjection, pinLoads: [String: Double]) throws -> Double {
        let e = projection.electrodes, n = e.network
        let components = Set(e.ports.filter { $0.terminal.netName.value == netID }.compactMap(\.componentIndex))
        guard components.count == 1, let component = components.first else { throw invalid("clock network open/component identity") }
        let active = Set(n.nodes.indices.filter { n.nodes[$0].componentIndex == component })
        var load = 0.0
        for c in n.capacitors {
            let a = active.contains(c.nodeA), b = c.nodeB.map { active.contains($0) } ?? false
            // Internal coupling is retained in the differential transient operator, not a common-mode lumped load.
            if a != b { load += c.farads }
        }
        for (pin, value) in pinLoads where projection.pinIndices[pin].map({ index in e.ports.contains { $0.pinIndex == index && $0.terminal.netName.value == netID } }) == true {
            guard value.isFinite, value > 0 else { throw invalid("source pin capacitance") }; load += value
        }
        guard load.isFinite, load > 0 else { throw invalid("finite positive distributed/lumped load") }; return load
    }

    mutating func measure(netID: String, sourcePinID: String, waveform: [PhysicalDesignClockTimingModel.Point], rising: Bool,
        projection: PhysicalDesignClockConductorProjection, pinLoads: [String: Double],
        characterization: PhysicalDesignClockCharacterization) async throws -> Result {
        let policy = characterization.model.numerics, e = projection.electrodes, n = e.network
        let ports = e.ports.indices.filter { e.ports[$0].terminal.netName.value == netID }
        guard let sourceIndex = projection.pinIndices[sourcePinID], let sourcePort = ports.first(where: { e.ports[$0].pinIndex == sourceIndex }),
              let component = e.ports[sourcePort].componentIndex,
              ports.allSatisfy({ e.ports[$0].componentIndex == component }) else { throw invalid("clock electrode source/open identity") }
        let active = Set(n.nodes.indices.filter { n.nodes[$0].componentIndex == component })
        var netlist = Netlist(), nodes: [String: Node] = [:]
        for i in active.sorted() { nodes["n\(i)"] = netlist.node("n\(i)") }
        for i in ports { nodes["p\(i)"] = netlist.node("p\(i)") }
        var count = 0
        func next(_ prefix: String) -> String { count += 1; return prefix + String(count) }
        for resistor in n.resistors where active.contains(resistor.nodeA) && active.contains(resistor.nodeB) {
            try netlist.addInstance(name: next("R"), typeName: "resistor", nodes: ["n\(resistor.nodeA)", "n\(resistor.nodeB)"], parameters: ["r": .real(resistor.ohms)])
        }
        for contact in e.contacts where ports.contains(contact.portIndex) {
            try netlist.addInstance(name: next("R"), typeName: "resistor", nodes: ["p\(contact.portIndex)", "n\(contact.nodeIndex)"], parameters: ["r": .real(contact.ohms)])
        }
        for capacitor in n.capacitors {
            let a = active.contains(capacitor.nodeA), b = capacitor.nodeB.map { active.contains($0) } ?? false
            guard a || b else { continue }
            let first = a ? "n\(capacitor.nodeA)" : "0", second = b ? "n\(capacitor.nodeB!)" : "0"
            try netlist.addInstance(name: next("C"), typeName: "capacitor", nodes: [first, second], parameters: ["c": .real(capacitor.farads)])
        }
        for i in ports {
            let id = e.ports[i].terminal.nodeName.value
            if let capacitance = pinLoads[id] {
                try netlist.addInstance(name: next("C"), typeName: "capacitor", nodes: ["p\(i)", "0"], parameters: ["c": .real(capacitance)])
            }
        }
        _ = netlist.branch()
        try netlist.addInstance(name: "clock_source", typeName: "vsource", nodes: ["p\(sourcePort)", "0"],
            parameters: ["pwl": .realVector(waveform.flatMap { [$0.time, $0.voltage] })])
        let ir = try netlist.build(), plan = try StandardCompiler().compile(ir: ir)
        let circuit = try StandardCircuitDeviceBinding().bind(plan: plan, instances: ir.instances)
        let initial = Dictionary(uniqueKeysWithValues: nodes.values.map { ($0, waveform[0].voltage) })
        let supply = characterization.corner.voltage!
        let thresholds = characterization.library.thresholds
        var previous: [String: Observation]?, stats: [TransientExecutionStatistics] = [], step = policy.maximumTimeStepSeconds
        for refinement in 0...policy.maximumRefinements {
            try Task.checkCancellation()
            guard step >= policy.minimumTimeStepSeconds, step.isFinite, step > 0 else { throw invalid("refinement minimum step") }
            try remaining.validate()
            let cancellation = CancellationToken()
            let config = TransientConfig(stopTime: policy.stopTimeSeconds, executionLimits: remaining, maxTimeStep: step, initialTimeStep: step,
                minTimeStep: policy.minimumTimeStepSeconds, initialMethod: .trapezoidal, lteTolerance: policy.lteTolerance,
                maxTimeStepReductions: policy.maximumStepReductions, useInitialConditions: true, initialNodeVoltages: initial, gminSteppingThreshold: Int.max)
            let result = try await withTaskCancellationHandler {
                try await TransientAnalysis(config: config, convergenceConfig: .init(abstol: policy.currentTolerance,
                    reltol: policy.relativeTolerance, vntol: policy.voltageTolerance, maxIterations: policy.maximumNewtonIterationsPerSolve, gmin: 0))
                    .run(circuit: circuit, solver: SparseLUSolver(), observer: nil, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
            guard let actual = result.executionStatistics, result.timePoints.last == policy.stopTimeSeconds else { throw invalid("actual bounded transient provenance/horizon") }
            try consume(actual); stats.append(actual)
            var observations: [String: Observation] = [:]
            for i in ports {
                try Task.checkCancellation()
                let id = e.ports[i].terminal.nodeName.value, node = nodes["p\(i)"]!
                var points: [PhysicalDesignClockTimingModel.Point] = []; points.reserveCapacity(result.timePoints.count)
                for (index, time) in result.timePoints.enumerated() {
                    let voltage = try result.voltage(at: node, timeIndex: index)
                    guard voltage.isFinite else { throw invalid("nonfinite transient voltage") }
                    points.append(.init(time: time, voltage: voltage))
                }
                let arrival = try PhysicalDesignClockWaveform.crossing(points,
                    level: supply * (rising ? thresholds.inputRise : thresholds.inputFall) / 100, rising: rising)
                let lower = try PhysicalDesignClockWaveform.crossing(points,
                    level: supply * (rising ? thresholds.slewLowerRise : thresholds.slewLowerFall) / 100, rising: rising)
                let upper = try PhysicalDesignClockWaveform.crossing(points,
                    level: supply * (rising ? thresholds.slewUpperRise : thresholds.slewUpperFall) / 100, rising: rising)
                let slew = abs(upper - lower)
                guard slew > 0 else { throw invalid("zero threshold slew") }
                observations[id] = .init(pinID: id, arrivalSeconds: arrival, slewSeconds: slew, waveform: points)
            }
            if let previous {
                let difference = observations.map { id, value in
                    max(abs(value.arrivalSeconds - previous[id]!.arrivalSeconds), abs(value.slewSeconds - previous[id]!.slewSeconds))
                }.max() ?? .infinity
                if difference <= policy.crossingAgreementSeconds {
                    return .init(loadFarads: try load(netID: netID, projection: projection, pinLoads: pinLoads), observations: observations,
                        statistics: stats, crossingDifferenceSeconds: difference, finalMaximumStepSeconds: step)
                }
            }
            guard refinement < policy.maximumRefinements else { throw invalid("threshold refinement agreement not achieved") }
            previous = observations; step /= 2
        }
        throw invalid("threshold refinement exhausted")
    }
    private mutating func consume(_ stats: TransientExecutionStatistics) throws {
        func subtract(_ available: Int, _ used: Int) throws -> Int {
            guard used >= 0, used <= available else { throw invalid("transient request budget/provenance") }; return available - used
        }
        remaining = try .init(maximumAcceptedSteps: subtract(remaining.maximumAcceptedSteps, stats.acceptedSteps),
            maximumSolveAttempts: subtract(remaining.maximumSolveAttempts, stats.solveAttempts),
            maximumNewtonIterations: subtract(remaining.maximumNewtonIterations, stats.newtonIterations),
            maximumSavedScalars: subtract(remaining.maximumSavedScalars, stats.savedScalars), maximumMatrixDimension: remaining.maximumMatrixDimension,
            maximumWorkUnits: subtract(remaining.maximumWorkUnits, stats.workUnits), maximumBreakpoints: remaining.maximumBreakpoints)
    }
    private func invalid(_ field: String) -> PhysicalDesignClockTimingModelError { .invalidModel(field) }
}
