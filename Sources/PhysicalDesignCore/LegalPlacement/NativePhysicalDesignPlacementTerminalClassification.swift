import LEF
import TimingCore

/// Source interpretation only; lower timing admission owns sequential eligibility.
struct NativePhysicalDesignPlacementTerminalClassification: Sendable {
    typealias Role = PhysicalDesignPlacementSourceBindings.Role
    typealias Coverage = PhysicalDesignPlacementSourceBindings.Coverage
    typealias TerminalBinding = PhysicalDesignPlacementSourceBindings.TerminalBinding
    typealias ConstantBinding = PhysicalDesignPlacementSourceBindings.ConstantBinding
    typealias SequentialBinding = PhysicalDesignPlacementSourceBindings.SequentialBinding

    let signalGraph: TimingDesign
    let terminals: [TerminalBinding]
    let constants: [ConstantBinding]
    let sequentialBindings: [SequentialBinding]
    private let source: OwnedLibertySource
    private let reservations: [LibertySourceStorageReservation]

    init(graph: TimingDesign, source: OwnedLibertySource, snapshot: PhysicalDesignSnapshot,
         inputs: PhysicalDesignProcessInputs, geometry: PhysicalDesignProcessGeometry,
         budget: NativePhysicalDesignPlacementTimingBudget) throws {
        try budget.check()
        guard graph.schemaVersion == TimingDesign.currentSchemaVersion,
              graph.topDesignName == snapshot.topCell, snapshot.unitsPerMicron == geometry.unitsPerMicron,
              snapshot.processManifest == geometry.manifestReference, snapshot.processAssets == geometry.sources else {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("Terminal classification requires exact source-bound snapshot and graph identities")
        }
        // Reserve a conservative logical envelope before allocating indices, graph COW or records.
        var payload: UInt64 = 0
        func admit(_ strings: String...) throws {
            var count: UInt64 = 512
            for string in strings {
                let bytes = UInt64(string.utf8.count).multipliedReportingOverflow(by: 16)
                let next = count.addingReportingOverflow(bytes.partialValue)
                guard !bytes.overflow, !next.overflow else { throw PhysicalDesignPlacementTimingError.resourceLimit("classification storage overflow") }
                count = next.partialValue
            }
            let next = payload.addingReportingOverflow(count)
            guard !next.overflow else { throw PhysicalDesignPlacementTimingError.resourceLimit("classification storage overflow") }
            payload = next.partialValue
            try budget.chargeWork(count)
        }
        for cell in source.cells {
            try admit(cell.name)
            for pin in cell.pins { try admit(pin.name) }
            for _ in cell.sequential { try admit() }
        }
        for document in inputs.cellViews.values {
            for master in document.macros {
                try admit(master.name)
                for pin in master.pins { try admit(pin.name) }
            }
        }
        for cell in snapshot.cells { try admit(cell.id, cell.master) }
        for pin in snapshot.pins { try admit(pin.id, pin.name, pin.cellID ?? "", pin.netID ?? "", pin.direction) }
        for net in snapshot.nets { try admit(net.id); for id in net.pinIDs { try admit(id) } }
        for instance in graph.instances {
            try admit(instance.name, instance.cell)
            for (pin, net) in instance.connections { try admit(pin, net) }
            // Source-only PG records repeat per occurrence even when no physical pin exists.
            for document in inputs.cellViews.values {
                for master in document.macros {
                    try budget.chargeWork(UInt64(master.name.utf8.count) + 1)
                    if master.name == instance.cell {
                        for pin in master.pins { try admit(instance.name, master.name, pin.name) }
                    }
                }
            }
            for cell in source.cells {
                try budget.chargeWork(UInt64(cell.name.utf8.count) + 1)
                if cell.name == instance.cell { for _ in cell.sequential { try admit(instance.name, cell.name) } }
            }
        }
        for port in graph.ports { try admit(port.name, port.netName) }
        for net in graph.nets { try admit(net.name) }
        let reservation = try budget.reserveStorage(kind: .liveOwnedBytes, byteCount: payload)
        func mismatch(_ reason: String) -> PhysicalDesignPlacementTimingError { .logicalMismatch(reason) }
        func direction(_ pin: LEFPinDef) throws -> String {
            switch pin.direction {
            case .input: return "input"
            case .output: return "output"
            case .inout_: return "inout"
            default: throw mismatch("Required LEF terminal direction is unavailable or unsupported")
            }
        }
        func role(_ pin: LEFPinDef) throws -> Role {
            switch pin.use {
            case .power: return .power
            case .ground: return .ground
            case nil, .signal, .clock: return .signal
            case .analog: throw mismatch("Analog terminal semantics are unavailable for placement timing")
            }
        }
        var sourceCells: [String: LibertySourceCell] = [:]
        for cell in source.cells {
            guard sourceCells.updateValue(cell, forKey: cell.name) == nil else { throw mismatch("Duplicate Liberty cell identity") }
        }
        var lefMasters: [String: (String, LEFMacroDef)] = [:]
        for (asset, document) in inputs.cellViews {
            for master in document.macros {
                guard lefMasters.updateValue((asset, master), forKey: master.name) == nil else { throw mismatch("Ambiguous LEF master identity") }
            }
        }
        var cells: [String: PhysicalDesignSnapshot.Cell] = [:]
        for cell in snapshot.cells {
            guard cells.updateValue(cell, forKey: cell.id) == nil else { throw mismatch("Duplicate physical instance") }
        }
        var pins: [String: PhysicalDesignSnapshot.Pin] = [:]
        var byInstance: [String: [String: PhysicalDesignSnapshot.Pin]] = [:]
        var topPins: [String: PhysicalDesignSnapshot.Pin] = [:]
        for pin in snapshot.pins {
            guard pins.updateValue(pin, forKey: pin.id) == nil else { throw mismatch("Duplicate physical terminal ID") }
            if let cell = pin.cellID {
                guard cells[cell] != nil, byInstance[cell, default: [:]].updateValue(pin, forKey: pin.name) == nil else {
                    throw mismatch("Unknown instance or duplicate physical terminal name")
                }
            } else {
                guard topPins.updateValue(pin, forKey: pin.name) == nil else { throw mismatch("Duplicate top terminal name") }
            }
        }
        var records: [TerminalBinding] = []
        var constantRecords: [ConstantBinding] = []
        var sequentialRecords: [SequentialBinding] = []
        var pinRoles: [String: Role] = [:]
        var signalInstances: [TimingDesign.Instance] = []
        var seenInstances: Set<String> = []
        var tieDrivers: [String: TimingDesign.Constant] = [:]
        var otherDrivenNets: Set<String> = []
        for instance in graph.instances {
            try budget.chargeWork(1)
            guard seenInstances.insert(instance.name).inserted, let cell = cells[instance.name], cell.master == instance.cell,
                  let liberty = sourceCells[cell.master], let (asset, lef) = lefMasters[cell.master],
                  let master = geometry.masters[cell.master], master.definition == lef else {
                throw mismatch("Instance/master must bind one exact Liberty and admitted LEF source")
            }
            var libertyPins: [String: LibertySourcePin] = [:]
            for pin in liberty.pins {
                try admitTraversal(pin.name, budget: budget)
                guard libertyPins.updateValue(pin, forKey: pin.name) == nil else { throw mismatch("Duplicate Liberty pin") }
                guard pin.direction == .internalPin || master.pins[pin.name] != nil else {
                    throw mismatch("Liberty signal terminal has no exact LEF declaration")
                }
            }
            var connections: [String: String] = [:]
            var declared: Set<String> = []
            let physical = byInstance[cell.id] ?? [:]
            for pin in lef.pins {
                try admitTraversal(pin.name, budget: budget)
                guard declared.insert(pin.name).inserted else { throw mismatch("Duplicate LEF pin") }
                let pinRole = try role(pin), pinDirection = try direction(pin)
                let actual = physical[pin.name]
                let logicalNet = instance.connections[pin.name]
                let sourcePin = libertyPins[pin.name]
                if pinRole == .signal {
                    guard let sourcePin, sourcePin.direction.rawValue == pinDirection else {
                        throw mismatch("Signal terminal direction differs between Liberty and LEF")
                    }
                    if actual != nil || logicalNet != nil {
                        guard let actual, let net = actual.netID, logicalNet == net, actual.direction == pinDirection else {
                            throw mismatch("Signal terminal requires exact physical/logical connectivity and direction")
                        }
                        connections[pin.name] = net
                    }
                } else {
                    guard sourcePin == nil else { throw mismatch("LEF supply conflicts with an ordinary Liberty signal pin") }
                    if let logicalNet { guard actual?.netID == logicalNet else { throw mismatch("Logical supply lacks its physical binding") } }
                    if let actual { guard actual.direction == pinDirection else { throw mismatch("Physical supply direction differs from LEF") } }
                }
                if let actual { pinRoles[actual.id] = pinRole }
                if let actual, pinRole == .signal, actual.direction == "output", let net = actual.netID {
                    // A literal source output is sufficient here; arbitrary expression evaluation belongs below.
                    if liberty.sequential.isEmpty, !liberty.pins.contains(where: { $0.direction == .input || $0.direction == .bidirectional }),
                       let function = sourcePin?.function, case .normalized(let facts) = function.content,
                       facts.symbols.isEmpty, facts.operations.count == 1, case .constant(let value) = facts.operations[0] {
                        let constant: TimingDesign.Constant = value ? .one : .zero
                        guard tieDrivers.updateValue(constant, forKey: net) == nil else { throw mismatch("Multiple tie drivers on one net") }
                        constantRecords.append(.init(netID: net, value: constant, kind: .sourceTieOutput, driverInstance: instance.name, driverPin: pin.name))
                    } else { otherDrivenNets.insert(net) }
                }
                if actual != nil || pinRole != .signal {
                    records.append(.init(physicalPinID: actual?.id, instanceID: instance.name, masterName: cell.master,
                        pinName: pin.name, netID: actual?.netID, lefAssetID: asset, role: pinRole,
                        coverage: actual == nil ? .sourceOnlySupply : (pinRole == .signal ? .boundSignal : .boundSupply),
                        direction: pinDirection, libertyCellOffset: liberty.byteOffset, libertyPinOffset: sourcePin?.byteOffset))
                }
            }
            guard physical.keys.allSatisfy({ declared.contains($0) }), instance.connections.keys.allSatisfy({ declared.contains($0) }) else {
                throw mismatch("Connected terminal has no exact LEF declaration")
            }
            if !liberty.sequential.isEmpty {
                var offsets: [Int] = []
                for sequential in liberty.sequential { try budget.chargeWork(1); offsets.append(sequential.byteOffset) }
                sequentialRecords.append(.init(instanceID: instance.name, masterName: cell.master,
                    sourceCellOffset: liberty.byteOffset, sourceSequentialOffsets: offsets))
            }
            signalInstances.append(.init(name: instance.name, cell: instance.cell, connections: connections))
        }
        guard seenInstances.count == cells.count else { throw mismatch("Physical instance inventory differs from graph") }
        var logicalPorts: [String: TimingDesign.Port] = [:]
        for port in graph.ports {
            guard logicalPorts.updateValue(port, forKey: port.name) == nil else { throw mismatch("Duplicate logical top port") }
        }
        var signalTopNames: Set<String> = []
        for pin in snapshot.pins where pin.cellID == nil {
            try budget.chargeWork(1)
            guard let surface = pin.topPort, pin.netID != nil, ["input", "output", "inout"].contains(pin.direction) else {
                throw mismatch("Top terminal requires an explicit source surface, net and direction")
            }
            let pinRole: Role
            switch surface.use {
            case .power: pinRole = .power
            case .ground: pinRole = .ground
            case .signal, .clock, .reset, .scan, .tieoff: pinRole = .signal
            default: throw mismatch("Top terminal USE is unsupported for timing classification")
            }
            if let port = logicalPorts.removeValue(forKey: pin.name) {
                guard port.netName == pin.netID, port.direction.rawValue == pin.direction else { throw mismatch("Top logical/source terminal differs") }
                if pinRole == .signal { signalTopNames.insert(port.name) }
            } else if pinRole == .signal { throw mismatch("Missing logical signal top port") }
            pinRoles[pin.id] = pinRole
            records.append(.init(physicalPinID: pin.id, instanceID: nil, masterName: nil, pinName: pin.name,
                netID: pin.netID, lefAssetID: nil, role: pinRole, coverage: pinRole == .signal ? .boundSignal : .boundSupply,
                direction: pin.direction, libertyCellOffset: nil, libertyPinOffset: nil))
        }
        guard logicalPorts.isEmpty else { throw mismatch("Logical top port lacks its physical terminal") }
        var netRoles: [String: Role] = [:]
        var incident: Set<String> = []
        for net in snapshot.nets {
            try budget.chargeWork(1)
            guard netRoles[net.id] == nil, !net.pinIDs.isEmpty else { throw mismatch("Duplicate or unclassified empty physical net") }
            var netRole: Role?
            for id in net.pinIDs {
                try budget.chargeWork(1)
                guard incident.insert(id).inserted, let pin = pins[id], pin.netID == net.id, let pinRole = pinRoles[id],
                      netRole == nil || netRole == pinRole else { throw mismatch("Net incidence or signal/supply roles conflict") }
                netRole = pinRole
            }
            guard let netRole else { throw mismatch("Net role is unknown") }
            if let use = net.defUse {
                switch use {
                case .power: guard netRole == .power else { throw mismatch("DEF POWER contradicts source terminals") }
                case .ground: guard netRole == .ground else { throw mismatch("DEF GROUND contradicts source terminals") }
                case .signal, .clock, .reset, .scan, .tieoff: guard netRole == .signal else { throw mismatch("DEF signal USE contradicts source supply") }
                default: throw mismatch("DEF net USE is unsupported for timing classification")
                }
            }
            guard !net.isClock || netRole == .signal else { throw mismatch("Supply cannot be classified as signal clock") }
            netRoles[net.id] = netRole
        }
        for pin in snapshot.pins where pin.netID != nil {
            guard incident.contains(pin.id) else { throw mismatch("Physical net omits its connected terminal") }
        }
        var signalNets: [TimingDesign.Net] = []
        var graphNets: Set<String> = []
        for net in graph.nets {
            try budget.chargeWork(1)
            guard graphNets.insert(net.name).inserted, let netRole = netRoles[net.name] else { throw mismatch("Logical net lacks one physical identity") }
            if netRole == .signal {
                if let value = net.constant {
                    guard !otherDrivenNets.contains(net.name), tieDrivers[net.name] == nil || tieDrivers[net.name] == value else {
                        throw mismatch("Logical constant contradicts its actual source driver")
                    }
                    constantRecords.append(.init(netID: net.name, value: value, kind: .logicalLiteral, driverInstance: nil, driverPin: nil))
                }
                signalNets.append(net)
            } else if net.constant != nil { throw mismatch("Supply is not a logical constant") }
        }
        guard netRoles.allSatisfy({ $0.value != .signal || graphNets.contains($0.key) }) else { throw mismatch("Physical signal net is absent from graph") }
        var signalPorts: [TimingDesign.Port] = []
        for port in graph.ports where signalTopNames.contains(port.name) { signalPorts.append(port) }
        var output = graph
        output.instances = signalInstances; output.ports = signalPorts; output.nets = signalNets
        self.signalGraph = output; self.terminals = records; self.constants = constantRecords
        self.sequentialBindings = sequentialRecords; self.source = source; self.reservations = [reservation]
    }
}

private func admitTraversal(_ name: String, budget: NativePhysicalDesignPlacementTimingBudget) throws {
    try budget.chargeWork(UInt64(name.utf8.count) + 1)
}
