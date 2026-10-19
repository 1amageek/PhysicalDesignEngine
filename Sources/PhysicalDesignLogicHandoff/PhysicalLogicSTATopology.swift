import LogicIR
import LogicKernelCore
import TimingCore

/// Projects only the signal graph already admitted by the immutable assessment.
internal enum PhysicalLogicSTATopology {
    static func workspaceBytes(_ assessment: borrowing PhysicalLogicECOAssessment,
                               limits: PhysicalLogicHandoffLimits,
                               context: inout LogicKernelContext) throws -> UInt64 {
        try context.checkpoint()
        let snapshot = assessment.candidate
        guard snapshot.cells.count <= limits.maximumInstances,
              snapshot.pins.count <= limits.maximumPins,
              snapshot.nets.count <= limits.maximumNets else {
            throw PhysicalLogicHandoffError.resourceLimit("STA binding projection capacity exceeded")
        }
        // These are logical payload reservations, not a Swift allocator/RSS guarantee.
        // Strings borrow immutable source backing; only output records and map slots grow.
        var bytes = UInt64(MemoryLayout<TimingDesign>.stride)
        for (count, stride) in [
            (snapshot.cells.count, MemoryLayout<TimingDesign.Instance>.stride),
            (snapshot.pins.count, MemoryLayout<TimingDesign.Port>.stride + MemoryLayout<(String, String)>.stride),
            (snapshot.nets.count, MemoryLayout<TimingDesign.Net>.stride + MemoryLayout<String>.stride)
        ] {
            let payload = UInt64(count).multipliedReportingOverflow(by: UInt64(stride))
            let total = bytes.addingReportingOverflow(payload.partialValue)
            guard !payload.overflow, !total.overflow else {
                throw PhysicalLogicHandoffError.resourceLimit("STA binding workspace size overflows")
            }
            bytes = total.partialValue
        }
        return bytes
    }

    /// The caller holds the workspace reservation until the returned graph is discarded.
    static func build(_ assessment: borrowing PhysicalLogicECOAssessment,
                      context: inout LogicKernelContext) throws -> TimingDesign {
        try assessment.mapped.withTables { nets, instances, pins, ports, bits, _ in
            var names: [String] = []
            names.reserveCapacity(nets.count)
            for index in nets.indices {
                let net = nets[index]
                try context.charge(.workUnits)
                guard let name = assessment.correspondence.netIDs[net.id] else {
                    throw PhysicalLogicHandoffError.invalidMapping("Missing assessed net correspondence")
                }
                names.append(name)
            }
            var timingNets: [TimingDesign.Net] = []
            timingNets.reserveCapacity(nets.count)
            for index in nets.indices {
                try context.charge(.workUnits)
                let constant: TimingDesign.Constant?
                if case .constant(let value) = nets[index].driver { constant = value ? .one : .zero }
                else { constant = nil }
                // Snapshot signal topology has no inline timing capacitance. PEX stays separate.
                timingNets.append(.init(name: names[index], constant: constant))
            }
            var timingInstances: [TimingDesign.Instance] = []
            timingInstances.reserveCapacity(instances.count)
            for index in instances.indices {
                let instance = instances[index]
                try context.charge(.workUnits)
                guard let name = assessment.correspondence.instanceIDs[instance.id] else {
                    throw PhysicalLogicHandoffError.invalidMapping("Missing assessed instance correspondence")
                }
                let cell = try assessment.mapped.library.cell(at: instance.cell)
                var connections: [String: String] = [:]
                connections.reserveCapacity(cell.pinCount)
                for offset in 0..<cell.pinCount {
                    let pin = try cell.pin(at: .init(offset))
                    try charge(pin.name, context: &context)
                    connections[pin.name] = names[pins[instance.pins.lowerBound + offset].rawValue]
                }
                timingInstances.append(.init(name: name, cell: cell.name, connections: connections))
            }
            var timingPorts: [TimingDesign.Port] = []
            timingPorts.reserveCapacity(assessment.baseline.original.portBitCount)
            for index in ports.indices {
                let port = ports[index]
                try context.charge(.workUnits)
                guard let physical = assessment.correspondence.portPinIDs[port.id],
                      physical.count == port.bits.count else {
                    throw PhysicalLogicHandoffError.invalidMapping("Missing assessed port correspondence")
                }
                for offset in physical.indices {
                    var name: String?
                    for pin in assessment.candidate.pins {
                        try charge(pin.id, context: &context)
                        if pin.id == physical[offset] { name = pin.name; break }
                    }
                    guard let name, !name.isEmpty else {
                        throw PhysicalLogicHandoffError.invalidMapping("Missing exact physical port name")
                    }
                    let net = names[bits[port.bits.lowerBound + offset].rawValue]
                    timingPorts.append(.init(name: name,
                        direction: port.direction == .input ? .input : .output, net: net))
                }
            }
            return TimingDesign(topDesignName: assessment.candidate.topCell,
                ports: timingPorts, instances: timingInstances, nets: timingNets)
        }
    }

    private static func charge(_ name: borrowing String,
                               context: inout LogicKernelContext) throws(LogicKernelError) {
        try context.charge(.workUnits, amount: UInt64(name.utf8.count) + 1)
    }
}
