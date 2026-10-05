import Foundation
import TimingCore

/// Builds unpublished finite candidates, using the placement/router and numerical owners.
struct NativePhysicalDesignClockTreeSynthesizer {
    func synthesize(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
                    geometry: PhysicalDesignProcessGeometry, characterization: PhysicalDesignClockCharacterization) async throws -> PhysicalDesignSnapshot {
        // FIXME(INCOMPLETE_IMPLEMENTATION): Retained-tree recharacterization has no native implementation. Source-bound API/CLI execution requires a pre-CTS snapshot until every retained path is independently remeasured.
        guard input.clockTrees.isEmpty else { throw invalid("retained tree recharacterization unsupported") }
        var budget = PhysicalDesignClockTransientMeasurement(limits: characterization.model.numerics.transient)
        var current = input, trees: [PhysicalDesignSnapshot.ClockTree] = []
        for clock in characterization.model.clocks.sorted(by: { $0.netID < $1.netID }) {
            try Task.checkCancellation()
            let modes = clock.topology == .directThenBuffered ? [false, true] : [clock.topology == .bufferEachSink]
            var admitted: PhysicalDesignSnapshot?
            for buffered in modes {
                let candidate = try topology(current, clock: clock, buffered: buffered, configuration: configuration, geometry: geometry)
                var routed = candidate.snapshot
                do {
                    for netID in candidate.family.sorted() {
                        routed = try PhysicalDesignSourceRouter().route(routed, configuration: configuration, mode: "cts", onlyNetID: netID, geometry: geometry).snapshot
                    }
                } catch let error as PhysicalDesignSourceRouter.Failure {
                    if !buffered, modes.count == 2, ["routing_path_unavailable", "routing_pin_access_unavailable", "routing_connectivity_missing"].contains(error.code) { continue }
                    throw error
                }
                let pinIDs = Set(routed.nets.filter { candidate.family.contains($0.id) }.flatMap(\.pinIDs))
                let projection = try PhysicalDesignClockConductorProjection(snapshot: routed, geometry: geometry, characterization: characterization, selectedPins: pinIDs)
                let cells = Dictionary(uniqueKeysWithValues: routed.cells.map { ($0.id, $0) })
                let pins = Dictionary(uniqueKeysWithValues: routed.pins.map { ($0.id, $0) })
                var loads: [String: Double] = [:], capacitanceSources: [String: String] = [:]
                for id in pinIDs {
                    guard let pin = pins[id] else { throw invalid("candidate pin identity") }
                    if pin.direction == "input" {
                        guard let cell = pin.cellID.flatMap({ cells[$0] }) else { throw invalid("source-bound input cell") }
                        loads[id] = try characterization.library.pinCapacitance(cell: cell.master, pin: pin.name)
                        capacitanceSources[id] = try characterization.library.pinCapacitanceSource(cell: cell.master, pin: pin.name).rawValue
                    }
                }
                let t = characterization.library.thresholds, supply = characterization.corner.voltage!
                var cellEvidence: [PhysicalDesignClockTimingEvidence.Cell] = []
                var sinkEvidence: [PhysicalDesignClockTimingEvidence.Sink] = [], netEvidence: [PhysicalDesignClockTimingEvidence.Net] = []
                for rising in [true, false] {
                    let rootWaveform = rising ? clock.rise : clock.fall
                    let rootTime = try PhysicalDesignClockWaveform.crossing(rootWaveform,
                        level: supply * (rising ? t.outputRise : t.outputFall) / 100, rising: rising)
                    let root = try await budget.measure(netID: clock.netID, sourcePinID: clock.sourcePinID, waveform: rootWaveform, rising: rising,
                        projection: projection, pinLoads: loads, characterization: characterization)
                    netEvidence.append(netEvidenceValue(root, id: clock.netID))
                    for sinkID in clock.sinkPinIDs.sorted() {
                        let observation: PhysicalDesignClockTransientMeasurement.Observation
                        let sinkRising: Bool
                        if let branch = candidate.branches[sinkID] {
                            guard let upstream = root.observations[branch.inputPinID] else { throw invalid("buffer input waveform") }
                            let sense = try characterization.library.arcSense(cell: branch.master, fromPin: branch.inputName, toPin: branch.outputName)
                            guard sense != .nonUnate else { throw invalid("non-unate clock driver unsupported") }
                            sinkRising = sense == .positiveUnate ? rising : !rising
                            let load = try budget.load(netID: branch.netID, projection: projection, pinLoads: loads)
                            let sample = try characterization.library.evaluate(cell: branch.master, fromPin: branch.inputName, toPin: branch.outputName,
                                edge: sinkRising ? .rise : .fall, inputSlew: upstream.slewSeconds, outputLoad: load)
                            let driver = try PhysicalDesignClockWaveform.scaled(sinkRising ? clock.bufferRiseShape : clock.bufferFallShape,
                                rising: sinkRising, arrival: upstream.arrivalSeconds + sample.delay, slew: sample.outputSlew,
                                delayThreshold: sinkRising ? t.outputRise : t.outputFall,
                                lower: sinkRising ? t.slewLowerRise : t.slewLowerFall, upper: sinkRising ? t.slewUpperRise : t.slewUpperFall,
                                supply: supply, horizon: characterization.model.numerics.stopTimeSeconds)
                            cellEvidence.append(.init(master: branch.master, inputPinID: branch.inputPinID, outputPinID: branch.outputPinID,
                                inputEdge: rising ? "rise" : "fall", outputEdge: sinkRising ? "rise" : "fall", inputArrivalSeconds: upstream.arrivalSeconds,
                                inputSlewSeconds: upstream.slewSeconds, outputLoadFarads: load, delaySeconds: sample.delay,
                                outputSlewSeconds: sample.outputSlew, prescribedOutputWaveform: driver))
                            let child = try await budget.measure(netID: branch.netID, sourcePinID: branch.outputPinID, waveform: driver,
                                rising: sinkRising, projection: projection, pinLoads: loads, characterization: characterization)
                            netEvidence.append(netEvidenceValue(child, id: branch.netID))
                            guard let sink = child.observations[sinkID] else { throw invalid("child sink waveform") }; observation = sink
                        } else {
                            sinkRising = rising
                            guard let sink = root.observations[sinkID] else { throw invalid("direct sink waveform") }; observation = sink
                        }
                        let latency = observation.arrivalSeconds - rootTime
                        guard latency.isFinite else { throw invalid("sink latency") }
                        sinkEvidence.append(.init(pinID: sinkID, rootEdge: rising ? "rise" : "fall", sinkEdge: sinkRising ? "rise" : "fall",
                            arrivalSeconds: observation.arrivalSeconds, latencySeconds: latency, slewSeconds: observation.slewSeconds, waveform: observation.waveform))
                    }
                }
                let skews = ["rise", "fall"].map { edge in
                    let arrivals = sinkEvidence.filter { $0.rootEdge == edge }.map(\.arrivalSeconds)
                    return (arrivals.max() ?? 0) - (arrivals.min() ?? 0)
                }
                let constraints = characterization.model.constraints
                let latency = sinkEvidence.map(\.latencySeconds).max()!, skew = skews.max()!
                let satisfied = sinkEvidence.allSatisfy { $0.latencySeconds <= constraints.maximumLatencySeconds && $0.slewSeconds <= constraints.maximumSlewSeconds }
                    && skew <= constraints.maximumSkewSeconds && netEvidence.allSatisfy { $0.loadFarads <= constraints.maximumLoadFarads }
                guard satisfied else { continue }
                let lower = projection.electrodes.network
                let evidence = PhysicalDesignClockTimingEvidence(cells: cellEvidence, inputCapacitanceSources: capacitanceSources, rcCornerID: characterization.model.rcCornerID, method: characterization.model.method.rawValue,
                    quietBoundary: characterization.model.quietBoundary.rawValue,
                    driverAssumption: "NLDM lumped-load evaluation; caller-declared normalized PWL; prescribed ideal output voltage; distributed passive RC; no CCS",
                    driverComposition: .nldmLumpedLoadCallerPWLDistributedPassiveRC, qualification: .unqualifiedPhysicalSignoff, constraintsSatisfied: true, sinks: sinkEvidence, nets: netEvidence,
                    standardDefaultAttributes: characterization.library.standardDefaultAttributes.sorted(),
                    thresholdsPercent: ["inputRise": t.inputRise, "inputFall": t.inputFall, "outputRise": t.outputRise, "outputFall": t.outputFall,
                        "slewLowerRise": t.slewLowerRise, "slewUpperRise": t.slewUpperRise, "slewLowerFall": t.slewLowerFall, "slewUpperFall": t.slewUpperFall],
                    meshCellCount: lower.nodes.count, resistorCount: lower.resistors.count, capacitorCount: lower.capacitors.count,
                    electrodeContactCount: projection.electrodes.contacts.count)
                let reference = characterization.reference
                trees.append(.init(id: "clock_tree_" + clock.netID, netID: clock.netID, sourcePinID: clock.sourcePinID,
                    sinkPinIDs: clock.sinkPinIDs.sorted(), bufferCellIDs: candidate.bufferIDs,
                    timingEstimate: .init(cornerID: characterization.model.cornerID, estimatedSkewPS: skew * 1e12, estimatedLatencyPS: latency * 1e12,
                        modelDigest: reference.modelArtifact.reference.digest.hexadecimalValue, pdkManifestDigest: characterization.model.pdkManifestDigest,
                        rcModelDigest: characterization.model.rcModelDigest, cellLibraryDigest: characterization.model.cellLibraryDigest, observations: evidence)))
                admitted = routed; break
            }
            guard let admitted else { throw invalid("modeled clock constraints unsatisfied by the explicit finite topology policy") }
            current = admitted
        }
        try Task.checkCancellation()
        current.clockTrees = trees
        current.metadata["clockTreeStatus"] = "constructed"
        current.metadata["clockTimingStatus"] = "passive_rc_model_constraints_satisfied_unqualified"
        return current
    }
    private struct Branch {
        let netID: String, master: String, inputPinID: String, outputPinID: String, inputName: String, outputName: String
    }
    private struct Candidate { let snapshot: PhysicalDesignSnapshot; let family: Set<String>; let branches: [String: Branch]; let bufferIDs: [String] }
    private func topology(_ input: PhysicalDesignSnapshot, clock: PhysicalDesignClockTimingModel.Clock, buffered: Bool,
        configuration: PhysicalDesignConfiguration, geometry: PhysicalDesignProcessGeometry) throws -> Candidate {
        var output = input, branches: [String: Branch] = [:], family: Set<String> = [clock.netID], buffers: [String] = []
        guard buffered else { return .init(snapshot: output, family: family, branches: branches, bufferIDs: buffers) }
        guard let masterName = clock.bufferMaster else { throw invalid("explicit buffer master") }
        let master = try geometry.requireMaster(masterName), ports = try geometry.bufferPorts(master: masterName)
        let originalLocks = Dictionary(uniqueKeysWithValues: output.cells.map { ($0.id, $0.locked) })
        for index in output.cells.indices { output.cells[index].locked = true }
        var upstream = [clock.sourcePinID]
        for sinkID in clock.sinkPinIDs.sorted() {
            try Task.checkCancellation()
            let id = "cts_\(clock.netID)_\(sinkID)", net = id + "_branch", inputID = id + "_input", outputID = id + "_output"
            guard !output.cells.contains(where: { $0.id == id }), !output.nets.contains(where: { $0.id == net }),
                  !output.pins.contains(where: { $0.id == inputID || $0.id == outputID }),
                  let sinkIndex = output.pins.firstIndex(where: { $0.id == sinkID }) else { throw invalid("candidate identity collision") }
            let cell = PhysicalDesignSnapshot.Cell(id: id, master: masterName, width: master.width, height: master.height, isClockBuffer: true)
            output.cells.append(cell)
            output.pins.append(try geometry.referencePin(.init(id: inputID, cellID: id, name: ports.input, netID: clock.netID), for: cell))
            output.pins.append(try geometry.referencePin(.init(id: outputID, cellID: id, name: ports.output, netID: net), for: cell))
            output.pins[sinkIndex].netID = net
            output.nets.append(.init(id: net, pinIDs: [outputID, sinkID], isClock: true, routingClass: .regular, defUse: .clock)); family.insert(net); buffers.append(id); upstream.append(inputID)
            branches[sinkID] = .init(netID: net, master: masterName, inputPinID: inputID, outputPinID: outputID, inputName: ports.input, outputName: ports.output)
        }
        guard let index = output.nets.firstIndex(where: { $0.id == clock.netID }) else { throw invalid("clock net identity") }
        output.nets[index].pinIDs = upstream.sorted()
        output = try NativePhysicalDesignPlacementAllocator().allocate(output, configuration: configuration, processGeometry: geometry).snapshot
        for index in output.cells.indices { output.cells[index].locked = originalLocks[output.cells[index].id] ?? false }
        // Pin positions/access layers are recomputed by the source owner after legal orientations are selected.
        for index in output.pins.indices {
            if let cell = output.cells.first(where: { $0.id == output.pins[index].cellID }), buffers.contains(cell.id) {
                output.pins[index] = try geometry.referencePin(output.pins[index], for: cell)
            }
        }
        output = try geometry.bind(output)
        output.implementationState?.placementProof = nil
        output.implementationState?.routingEvidence = nil
        output.implementationState?.repairProofs = []
        return .init(snapshot: output, family: family, branches: branches, bufferIDs: buffers)
    }
    private func netEvidenceValue(_ value: PhysicalDesignClockTransientMeasurement.Result, id: String) -> PhysicalDesignClockTimingEvidence.Net {
        .init(netID: id, loadFarads: value.loadFarads, maximumStepSeconds: value.finalMaximumStepSeconds,
            crossingDifferenceSeconds: value.crossingDifferenceSeconds, statistics: value.statistics)
    }
    private func invalid(_ reason: String) -> PhysicalDesignClockTimingModelError { .invalidModel(reason) }
}
