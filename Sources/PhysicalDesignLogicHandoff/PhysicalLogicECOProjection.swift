import CircuiteFoundation
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import LogicProof
import PhysicalDesignCore

internal enum PhysicalLogicECOProjection {
    static func build(_ synthesis: LogicVerifiedSynthesis, candidate: PhysicalDesignSnapshot,
                      correspondence: PhysicalLogicECOCorrespondence, limits: PhysicalLogicHandoffLimits,
                      context: inout LogicKernelContext) throws -> MappedGateDesign {
        try context.checkpoint()
        guard candidate.cells.count <= limits.maximumInstances, candidate.pins.count <= limits.maximumPins,
              candidate.nets.count <= limits.maximumNets, synthesis.original.portBitCount <= limits.maximumPins,
              correspondence.instanceIDs.count <= limits.maximumInstances,
              correspondence.netIDs.count <= limits.maximumNets,
              correspondence.portPinIDs.count <= limits.maximumPins,
              correspondence.stateInstanceIDs.count <= limits.maximumInstances else {
            throw PhysicalLogicHandoffError.resourceLimit("ECO projection table capacity exceeded")
        }
        guard candidate.schemaVersion == 2, candidate.topCell == synthesis.request.top,
              correspondence.instanceIDs.count == candidate.cells.count,
              correspondence.netIDs.count == candidate.nets.count,
              correspondence.portPinIDs.count == synthesis.original.portCount,
              correspondence.stateInstanceIDs.count == synthesis.original.stateCount else {
            throw PhysicalLogicHandoffError.invalidMapping("ECO correspondence is not total")
        }
        var memberships = 0, portBits = 0
        for net in candidate.nets {
            try context.charge(.workUnits)
            let next = memberships.addingReportingOverflow(net.pinIDs.count)
            guard !next.overflow, next.partialValue <= limits.maximumPins else {
                throw PhysicalLogicHandoffError.resourceLimit("ECO net membership capacity exceeded")
            }
            memberships = next.partialValue
        }
        for pins in correspondence.portPinIDs.values {
            try context.charge(.workUnits)
            let next = portBits.addingReportingOverflow(pins.count)
            guard !next.overflow, next.partialValue <= limits.maximumPins else {
                throw PhysicalLogicHandoffError.resourceLimit("ECO port correspondence capacity exceeded")
            }
            portBits = next.partialValue
        }
        guard memberships == candidate.pins.count, portBits == synthesis.original.portBitCount else {
            throw PhysicalLogicHandoffError.invalidMapping("ECO pin coverage differs from the complete interface")
        }
        // Source-boundary lookups are bounded linear scans. Dense scratch payloads have
        // explicit strides; no hash-table bucket estimate or copied name table is needed.
        var bytes = UInt64(MemoryLayout<([DesignEntityID], [DesignEntityID], [LogicCellIndex], [Int],
            [DesignEntityID?], [Bool?], [Bool], [MappedGateNet.Driver?], [MappedNetIndex])>.stride)
        for (count, stride) in [
            (candidate.cells.count, MemoryLayout<DesignEntityID>.stride + MemoryLayout<LogicCellIndex>.stride
                + MemoryLayout<DesignEntityID?>.stride + MemoryLayout<Bool?>.stride),
            (candidate.pins.count, MemoryLayout<Int>.stride + MemoryLayout<Bool>.stride),
            (candidate.nets.count, MemoryLayout<DesignEntityID>.stride + MemoryLayout<MappedGateNet.Driver?>.stride),
            (candidate.pins.count, MemoryLayout<MappedNetIndex>.stride)] {
            let payload = UInt64(count).multipliedReportingOverflow(by: UInt64(stride))
            let total = bytes.addingReportingOverflow(payload.partialValue)
            guard !payload.overflow, !total.overflow else { throw LogicKernelError.invalidInput("ECO workspace size overflows") }
            bytes = total.partialValue
        }
        let reservation = try context.reserveStorage(byteCount: bytes)
        let graph: MappedGateDesign
        do {
            graph = try buildTables(synthesis, candidate: candidate, correspondence: correspondence, context: &context)
        } catch { try context.releaseStorage(reservation); throw error }
        try context.releaseStorage(reservation)
        return graph
    }

    private static func canonicalID(_ physical: String, in mapping: [DesignEntityID: String],
                                    context: inout LogicKernelContext) throws -> DesignEntityID {
        var matched: DesignEntityID?
        for (canonical, value) in mapping {
            try context.charge(.workUnits)
            if physical == value {
                guard matched == nil else { throw PhysicalLogicHandoffError.invalidMapping("Physical correspondence is not unique") }
                matched = canonical
            }
        }
        guard !physical.isEmpty, let matched else { throw PhysicalLogicHandoffError.invalidMapping("Missing physical correspondence") }
        return matched
    }

    private static func buildTables(_ synthesis: LogicVerifiedSynthesis, candidate: PhysicalDesignSnapshot,
                                    correspondence: PhysicalLogicECOCorrespondence,
                                    context: inout LogicKernelContext) throws -> MappedGateDesign {
        var instanceIDs: [DesignEntityID] = [], netIDs: [DesignEntityID] = [], definitions: [LogicCellIndex] = []
        instanceIDs.reserveCapacity(candidate.cells.count); definitions.reserveCapacity(candidate.cells.count)
        netIDs.reserveCapacity(candidate.nets.count)
        func cellIndex(_ id: String) throws -> Int {
            for index in candidate.cells.indices {
                try context.charge(.workUnits)
                if candidate.cells[index].id == id { return index }
            }
            throw PhysicalLogicHandoffError.invalidMapping("Unknown candidate cell identity")
        }
        func pinIndex(_ id: String) throws -> Int {
            for index in candidate.pins.indices {
                try context.charge(.workUnits)
                if candidate.pins[index].id == id { return index }
            }
            throw PhysicalLogicHandoffError.invalidMapping("Unknown candidate pin identity")
        }
        for (index, physical) in candidate.cells.enumerated() {
            guard try cellIndex(physical.id) == index else { throw PhysicalLogicHandoffError.invalidMapping("Duplicate candidate cell identity") }
            instanceIDs.append(try canonicalID(physical.id, in: correspondence.instanceIDs, context: &context))
            var definition: LogicCellIndex?
            for cell in 0..<synthesis.mapped.library.cellCount {
                try context.charge(.workUnits)
                if try synthesis.mapped.library.cell(at: .init(cell)).name == physical.master {
                    guard definition == nil else { throw PhysicalLogicHandoffError.invalidMapping("Ambiguous compiled master name") }
                    definition = .init(cell)
                }
            }
            guard let definition else { throw PhysicalLogicHandoffError.invalidMapping("Unknown exact compiled library master") }
            definitions.append(definition)
        }
        for (index, pin) in candidate.pins.enumerated() {
            guard !pin.id.isEmpty, try pinIndex(pin.id) == index else { throw PhysicalLogicHandoffError.invalidMapping("Duplicate or empty candidate pin identity") }
            if let owner = pin.cellID { _ = try cellIndex(owner) }
        }
        var pinNets = [Int](repeating: -1, count: candidate.pins.count)
        for (index, net) in candidate.nets.enumerated() {
            netIDs.append(try canonicalID(net.id, in: correspondence.netIDs, context: &context))
            for previous in 0..<index {
                try context.charge(.workUnits)
                guard candidate.nets[previous].id != net.id else { throw PhysicalLogicHandoffError.invalidMapping("Duplicate candidate net identity") }
            }
            for name in net.pinIDs {
                let pin = try pinIndex(name)
                guard pinNets[pin] == -1, candidate.pins[pin].netID == net.id else {
                    throw PhysicalLogicHandoffError.logicalMismatch("Candidate net membership is duplicated or contradictory")
                }
                pinNets[pin] = index
            }
        }
        guard !pinNets.contains(-1) else { throw PhysicalLogicHandoffError.logicalMismatch("Unconnected candidate pin") }
        var stateIDs = [DesignEntityID?](repeating: nil, count: candidate.cells.count)
        var initials = [Bool?](repeating: nil, count: candidate.cells.count)
        try synthesis.original.withTables { _, _, _, _, states, _ in
            for index in states.indices {
                let state = states[index]
                try context.charge(.workUnits)
                guard let physical = correspondence.stateInstanceIDs[state.id] else {
                    throw PhysicalLogicHandoffError.invalidMapping("Missing original state correspondence")
                }
                let cell = try cellIndex(physical)
                guard stateIDs[cell] == nil else { throw PhysicalLogicHandoffError.invalidMapping("State correspondence is not unique") }
                stateIDs[cell] = state.id; initials[cell] = state.initialValue
            }
        }
        var used = [Bool](repeating: false, count: candidate.pins.count)
        var drivers = [MappedGateNet.Driver?](repeating: nil, count: candidate.nets.count)
        func use(_ index: Int, cell: String?, direction: String, driver: MappedGateNet.Driver?) throws {
            try context.charge(.workUnits)
            let pin = candidate.pins[index]
            let correctDirection = pin.direction.utf8.elementsEqual(direction.utf8) { actual, expected in
                actual == expected || (actual >= 65 && actual <= 90 && actual + 32 == expected)
            }
            guard !used[index], pin.cellID == cell, correctDirection else {
                throw PhysicalLogicHandoffError.logicalMismatch("Candidate pin identity, direction or exclusive ownership differs")
            }
            used[index] = true
            if let driver {
                guard drivers[pinNets[index]] == nil else { throw PhysicalLogicHandoffError.logicalMismatch("Candidate net has multiple drivers") }
                drivers[pinNets[index]] = driver
            }
        }
        var builder = try MappedGateBuilder(library: synthesis.mapped.library,
            capacity: .init(nets: candidate.nets.count, instances: candidate.cells.count,
                pinConnections: candidate.pins.count - synthesis.original.portBitCount,
                ports: synthesis.original.portCount, portBits: synthesis.original.portBitCount), context: &context)
        for (index, physical) in candidate.cells.enumerated() {
            let definition = try synthesis.mapped.library.cell(at: definitions[index])
            guard definition.pinCount <= candidate.pins.count,
                  (definition.state != nil) == (stateIDs[index] != nil) else {
                throw PhysicalLogicHandoffError.invalidMapping("Candidate state correspondence differs from actual cell")
            }
            var connections: [MappedNetIndex] = []; connections.reserveCapacity(definition.pinCount)
            for offset in 0..<definition.pinCount {
                let pin = try definition.pin(at: .init(offset)); var matched: Int?
                for physicalPin in candidate.pins.indices {
                    try context.charge(.workUnits)
                    if candidate.pins[physicalPin].cellID == physical.id && candidate.pins[physicalPin].name == pin.name {
                        guard matched == nil else { throw PhysicalLogicHandoffError.logicalMismatch("Duplicate actual-cell pin name") }
                        matched = physicalPin
                    }
                }
                guard let matched else { throw PhysicalLogicHandoffError.logicalMismatch("Missing exact actual-cell pin") }
                try use(matched, cell: physical.id, direction: pin.direction == .input ? "input" : "output",
                    driver: pin.direction == .output ? .instanceOutput(.init(index), .init(offset)) : nil)
                connections.append(.init(pinNets[matched]))
            }
            _ = try builder.addInstance(id: instanceIDs[index], cell: definitions[index], pinNets: connections,
                stateID: stateIDs[index], initialValue: initials[index], context: &context)
        }
        try synthesis.original.withTables { _, _, ports, _, _, _ in
            for index in ports.indices {
                let port = ports[index]
                try context.charge(.workUnits)
                guard let physicalPins = correspondence.portPinIDs[port.id], physicalPins.count == port.bits.count else {
                    throw PhysicalLogicHandoffError.invalidMapping("Original port-bit correspondence is incomplete")
                }
                var connections: [MappedNetIndex] = []; connections.reserveCapacity(physicalPins.count)
                for id in physicalPins {
                    let pin = try pinIndex(id)
                    try use(pin, cell: nil, direction: port.direction == .input ? "input" : "output",
                            driver: port.direction == .input ? .input : nil)
                    connections.append(.init(pinNets[pin]))
                }
                try builder.addPort(id: port.id, direction: port.direction == .input ? .input : .output,
                                    nets: connections, context: &context)
            }
        }
        guard !used.contains(false) else { throw PhysicalLogicHandoffError.logicalMismatch("Unused or undeclared candidate pin") }
        for index in candidate.nets.indices {
            try context.charge(.workUnits)
            guard let driver = drivers[index] else { throw PhysicalLogicHandoffError.logicalMismatch("Undriven candidate net") }
            _ = try builder.addNet(.init(id: netIDs[index], driver: driver), context: &context)
        }
        return try builder.finish(context: &context)
    }

    static func problem(_ original: BitLogicDesign, mapped: MappedGateDesign,
                        context: inout LogicKernelContext) throws(LogicKernelError) -> LogicEquivalenceProblem {
        var inputs: [LogicBitCorrespondence] = [], outputs: [LogicBitCorrespondence] = [], states: [LogicBitCorrespondence] = []
        var inputCount = 0, outputCount = 0
        try original.withTables { _, _, ports, _, _, _ throws(LogicKernelError) in
            for index in ports.indices {
                try context.charge(.workUnits)
                if ports[index].direction == .input { inputCount += ports[index].bits.count }
                else { outputCount += ports[index].bits.count }
            }
        }
        let count = original.portBitCount.addingReportingOverflow(original.stateCount)
        let bytes = UInt64(count.partialValue).multipliedReportingOverflow(by: UInt64(MemoryLayout<LogicBitCorrespondence>.stride))
        guard !count.overflow, !bytes.overflow else { throw .invalidInput("ECO proof correspondence size overflows") }
        _ = try context.reserveStorage(byteCount: bytes.partialValue)
        inputs.reserveCapacity(inputCount); outputs.reserveCapacity(outputCount); states.reserveCapacity(original.stateCount)
        for index in 0..<inputCount { try context.charge(.workUnits); inputs.append(try .init(reference: index, candidate: index)) }
        for index in 0..<outputCount { try context.charge(.workUnits); outputs.append(try .init(reference: index, candidate: index)) }
        try original.withTables { _, _, _, _, originalStates, _ throws(LogicKernelError) in
            try mapped.withTables { _, instances, _, _, _, _ throws(LogicKernelError) in
                for index in originalStates.indices {
                    var ordinal = 0, matched: Int?
                    for instanceIndex in instances.indices {
                        try context.charge(.workUnits)
                        if let id = instances[instanceIndex].stateID {
                            if id == originalStates[index].id { matched = ordinal }
                            ordinal += 1
                        }
                    }
                    guard let matched else { throw .invalidModel("Missing admitted candidate state") }
                    states.append(try .init(reference: index, candidate: matched))
                }
            }
        }
        return try .init(reference: .bit(original), candidate: .mapped(mapped), inputs: inputs,
                         outputs: outputs, states: states, context: &context)
    }
}
