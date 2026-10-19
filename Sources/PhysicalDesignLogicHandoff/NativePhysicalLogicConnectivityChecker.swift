import CircuiteFoundation
import LogicEngineRuntime
import LogicIR
import LogicKernelCore
import PhysicalDesignCore

public struct NativePhysicalLogicConnectivityChecker: PhysicalLogicConnectivityChecking {
    public init() {}
    public func check(_ synthesis: LogicVerifiedSynthesis, snapshot: PhysicalDesignSnapshot,
                      correspondence: PhysicalLogicCorrespondence,
                      limits: PhysicalLogicHandoffLimits) throws(PhysicalLogicHandoffError) -> CheckedPhysicalLogicHandoff {
        let mapped = synthesis.mapped
        guard mapped.instanceCount <= limits.maximumInstances, snapshot.cells.count <= limits.maximumInstances,
              mapped.pinConnectionCount <= limits.maximumPins, mapped.portBitCount <= limits.maximumPins,
              snapshot.pins.count <= limits.maximumPins, mapped.netCount <= limits.maximumNets,
              snapshot.nets.count <= limits.maximumNets else { throw .resourceLimit("Logical handoff table capacity exceeded") }
        guard synthesis.request.realizationPolicy == .physicalCells else {
            throw .unsupported("Physical handoff requires a checked physicalCells synthesis receipt")
        }
        do {
            try validateRealization(synthesis)
        } catch let error as LogicKernelError {
            switch error {
            case .unsupported(let message): throw .unsupported(message)
            case .resourceLimit: throw .resourceLimit("Physical realization work budget exceeded")
            default: throw .invalidMapping("Physical realization admission failed: \(error)")
            }
        } catch { throw .invalidMapping("Physical realization admission failed: \(error)") }
        guard snapshot.schemaVersion == 2, snapshot.topCell == synthesis.request.top,
              correspondence.instanceIDs.count == mapped.instanceCount, correspondence.portPinIDs.count == mapped.portCount,
              Set(correspondence.instanceIDs.values).count == mapped.instanceCount,
              snapshot.cells.count == mapped.instanceCount else { throw .invalidMapping("Instance/port correspondence is not total") }
        var membershipCount = 0
        for net in snapshot.nets {
            let total = membershipCount.addingReportingOverflow(net.pinIDs.count)
            guard !total.overflow, total.partialValue <= limits.maximumPins else { throw .resourceLimit("Physical net membership capacity exceeded") }
            membershipCount = total.partialValue
        }
        var cells: [String: PhysicalDesignSnapshot.Cell] = [:]
        var pins: [String: PhysicalDesignSnapshot.Pin] = [:]
        var cellPins: [String: [String: String]] = [:]
        var nets: [String: Set<String>] = [:]
        for cell in snapshot.cells {
            guard cells.updateValue(cell, forKey: cell.id) == nil else { throw .invalidMapping("Duplicate physical cell") }
        }
        for pin in snapshot.pins {
            guard pins.updateValue(pin, forKey: pin.id) == nil else { throw .invalidMapping("Duplicate physical pin") }
            if let cell = pin.cellID {
                guard cells[cell] != nil, cellPins[cell, default: [:]].updateValue(pin.id, forKey: pin.name) == nil else {
                    throw .invalidMapping("Unknown cell or duplicate physical pin name")
                }
            }
        }
        var membership: [String: String] = [:]
        for net in snapshot.nets {
            guard nets[net.id] == nil, !net.id.isEmpty, Set(net.pinIDs).count == net.pinIDs.count else { throw .invalidMapping("Duplicate physical net/membership") }
            nets[net.id] = Set(net.pinIDs)
            for pin in net.pinIDs {
                guard pins[pin]?.netID == net.id, membership.updateValue(net.id, forKey: pin) == nil else { throw .logicalMismatch("Physical pin/net membership differs") }
            }
        }
        guard membership.count == pins.count else { throw .logicalMismatch("Unconnected physical pin") }
        var matched = Set<String>(); var netMap: [Int: String] = [:]; var reverseNets: [String: Int] = [:]
        func bind(_ pinID: String, net: Int, cell: String?, name: String?, direction: String) throws(PhysicalLogicHandoffError) {
            guard let pin = pins[pinID], pin.cellID == cell, name == nil || pin.name == name,
                  pin.direction.lowercased() == direction, let actualNet = membership[pinID], matched.insert(pinID).inserted else {
                throw .logicalMismatch("Physical pin identity or direction differs")
            }
            guard netMap[net] == nil || netMap[net] == actualNet,
                  reverseNets[actualNet] == nil || reverseNets[actualNet] == net else { throw .logicalMismatch("Actual-cell net was split or joined") }
            netMap[net] = actualNet; reverseNets[actualNet] = net
        }
        do {
            try mapped.withTables { logicalNets, instances, connections, ports, bits, _ in
                for i in instances.indices {
                    guard let physicalID = correspondence.instanceIDs[instances[i].id], let physical = cells[physicalID] else { throw PhysicalLogicHandoffError.invalidMapping("Missing instance identity") }
                    let cell = try mapped.library.cell(at: instances[i].cell)
                    guard physical.master == cell.name, cellPins[physicalID]?.count == cell.pinCount else { throw PhysicalLogicHandoffError.logicalMismatch("Real master or physical pin set differs") }
                    for p in 0..<cell.pinCount {
                        let pin = try cell.pin(at: .init(p))
                        guard let physicalPin = cellPins[physicalID]?[pin.name] else { throw PhysicalLogicHandoffError.logicalMismatch("Missing real cell pin") }
                        try bind(physicalPin, net: connections[instances[i].pins.lowerBound + p].rawValue,
                                 cell: physicalID, name: pin.name, direction: pin.direction == .input ? "input" : "output")
                    }
                }
                for p in ports.indices {
                    guard let physicalPins = correspondence.portPinIDs[ports[p].id], physicalPins.count == ports[p].bits.count else { throw PhysicalLogicHandoffError.invalidMapping("Missing port bit identity") }
                    for b in physicalPins.indices {
                        try bind(physicalPins[b], net: bits[ports[p].bits.lowerBound + b].rawValue,
                                 cell: nil, name: nil, direction: ports[p].direction == .input ? "input" : "output")
                    }
                }
            }
        } catch let error as PhysicalLogicHandoffError { throw error }
        catch { throw .invalidMapping("Validated logical graph access failed: \(error)") }
        guard matched.count == pins.count, reverseNets.count == nets.count else { throw .logicalMismatch("Unused physical pins or nets") }
        return .init(synthesis: synthesis, snapshot: snapshot, correspondence: correspondence)
    }
    private func validateRealization(_ synthesis: LogicVerifiedSynthesis) throws {
        var context = LogicKernelContext(limits: try synthesis.request.limits.kernelLimits(),
            control: PhysicalLogicRealizationControl(timeoutNanoseconds: synthesis.request.limits.timeoutNanoseconds))
        try NativeMappedGateRealizationValidator().validate(synthesis.mapped, policy: .physicalCells, context: &context)
    }

}
