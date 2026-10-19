import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import STAEngine
import TimingCore

extension NativePhysicalDesignPlacementCharacterization {
    func projected(_ snapshot: PhysicalDesignSnapshot, geometry: PhysicalDesignProcessGeometry) throws -> TimingDesign {
        try budget.check()
        if profile.isSourceBoundSequential {
            guard rcProjection != nil, sourceBindings != nil, snapshot.clockTrees.isEmpty,
                  graph.nets.allSatisfy({ $0.capacitance == 0 }) else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Source RC requires the classified pre-route graph without a second wire-load authority")
            }
            return graph
        }
        let cells = Dictionary(uniqueKeysWithValues: snapshot.cells.map { ($0.id, $0) })
        let pins = Dictionary(uniqueKeysWithValues: snapshot.pins.map { ($0.id, $0) })
        guard graph.topDesignName == snapshot.topCell,
              Set(graph.instances.map(\.name)) == Set(cells.keys), graph.nets.allSatisfy({ $0.constant == nil }),
              !snapshot.nets.contains(where: { $0.isClock || $0.defUse == .power || $0.defUse == .ground }), snapshot.clockTrees.isEmpty else {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("Placement requires an exact combinational non-power signal graph")
        }
        for instance in graph.instances {
            guard let cell = cells[instance.name], cell.master == instance.cell else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Instance/master identity differs from the mapped source")
            }
            let master = try geometry.requireMaster(cell.master)
            let connected = snapshot.pins.filter { pin in
                guard pin.cellID == cell.id, let declared = master.pins[pin.name] else { return false }
                return declared.definition.use != .power && declared.definition.use != .ground
            }
            guard Set(connected.map(\.name)).count == connected.count,
                  instance.connections == Dictionary(uniqueKeysWithValues: connected.compactMap { pin in pin.netID.map { (pin.name, $0) } }) else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Connected instance/pin/net identities differ from the mapped source")
            }
        }
        let topPins = snapshot.pins.filter { $0.cellID == nil }
        guard Set(topPins.map(\.name)) == Set(graph.ports.map(\.name)), topPins.count == graph.ports.count,
              Set(snapshot.nets.map(\.id)) == Set(graph.nets.map(\.name)) else {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("Top-port or net inventory differs from the mapped source")
        }
        for port in graph.ports {
            guard let pin = topPins.first(where: { $0.name == port.name }), pin.netID == port.netName,
                  pin.direction == port.direction.rawValue, pin.topPort != nil else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Top ports require exact placed source surfaces and mapped connectivity")
            }
        }
        var output = graph
        let width = Double(profile.wireWidthDBU) / Double(snapshot.unitsPerMicron)
        for index in output.nets.indices {
            try budget.check()
            let name = output.nets[index].name
            guard let net = snapshot.nets.first(where: { $0.id == name }) else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Missing signal net")
            }
            let terminals = try net.pinIDs.map { id in
                guard let pin = pins[id], pin.netID == name else { throw PhysicalDesignPlacementTimingError.logicalMismatch("Net incidence differs") }
                return pin
            }
            let drivers = terminals.filter { $0.cellID == nil ? $0.direction == "input" : $0.direction == "output" }
            guard drivers.count == 1, let driver = drivers.first, terminals.count > 1,
                  terminals.allSatisfy({ $0.direction == "input" || $0.direction == "output" }) else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Every modeled net requires exactly one driver and explicit unidirectional sinks")
            }
            var capacitance = 0.0
            for sink in terminals where sink.id != driver.id {
                try budget.chargeWork(1)
                let length = (abs(Double(sink.x) - Double(driver.x)) + abs(Double(sink.y) - Double(driver.y))) / Double(snapshot.unitsPerMicron)
                if length > 0 {
                    // LEF electrical values are already in pF; unit declarations specify precision.
                    capacitance += (length * width * areaPicofaradsPerSquareMicron
                        + 2 * (length + width) * edgePicofaradsPerMicron) * 1e-12
                }
            }
            guard capacitance.isFinite, capacitance >= 0 else { throw PhysicalDesignPlacementTimingError.invalidProfile("Estimated wire capacitance is not finite") }
            output.nets[index].capacitance = capacitance
        }
        return output
    }

    func checkCharacterizedPaths(_ result: STAExecutionResult) throws {
        guard !profile.isSourceBoundSequential, let strict else {
            throw PhysicalDesignPlacementTimingError.unavailableTiming("Sequential evidence requires exact prepared-owner validation")
        }
        var covered = Set<String>()
        for path in result.payload.criticalPaths {
            var slew = constraints.defaultInputSlew
            for stage in path.stages {
                try budget.chargeWork(1)
                guard let instance = graph.instances.first(where: { $0.name == stage.instance }) else {
                    throw PhysicalDesignPlacementTimingError.logicalMismatch("STA path instance is unavailable")
                }
                let outputs = instance.connections.filter { $0.value == stage.outputNet && $0.key != stage.inputPin }
                guard outputs.count == 1, let output = outputs.first else {
                    throw PhysicalDesignPlacementTimingError.unavailableTiming("An STA path must identify one exact output pin")
                }
                let sample = try strict.evaluate(cell: stage.cell, fromPin: stage.inputPin, toPin: output.key,
                    edge: stage.outputEdge, inputSlew: slew, outputLoad: stage.load)
                guard sample.delay == stage.delay, sample.outputSlew == stage.outputSlew else {
                    throw PhysicalDesignPlacementTimingError.unavailableTiming("STA path differs from its strict source-characterized operating point")
                }
                slew = sample.outputSlew
                covered.insert(stage.instance)
            }
        }
        guard covered == Set(graph.instances.map(\.name)) else {
            throw PhysicalDesignPlacementTimingError.unavailableTiming("The complete mapped instance set lacks constrained characterized path coverage")
        }
    }
}
