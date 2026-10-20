import CoreSpice
import CoreSpiceIO

/// Checked interpretation of declared SPEF R=+0 as the existing ideal V=0 primitive.
internal final class PhysicalLogicWholeCandidateIdealConnections: Sendable {
    struct Row: Sendable {
        let sourceOrdinal: Int
        let instanceIndex: Int
        let branch: Branch
    }
    let source: PreparedSPICESimulation
    let circuit: CircuitIR
    let request: NativePrescribedVoltageFlowRequest
    let rows: [Row]
    private let storage: SPICESourceStorageReservation
    private init(source: PreparedSPICESimulation, circuit: CircuitIR, request: NativePrescribedVoltageFlowRequest,
        rows: [Row], storage: SPICESourceStorageReservation) {
        self.source = source; self.circuit = circuit; self.request = request; self.rows = rows; self.storage = storage
    }
    static func prepare(source: PreparedSPICESimulation, flow: NativePrescribedVoltageFlowRequest,
        control: PhysicalLogicWholeCandidateControl) throws -> Self? {
        var definition: ParsedSubcircuit?, call: ParsedComponent?
        for candidate in source.netlist.subcircuits {
            try control.check()
            if try control.symbol(candidate.name, "whole_pex") {
                guard definition == nil else { throw failure("Duplicate PEX definition") }; definition = candidate
            }
        }
        for candidate in source.netlist.components {
            try control.check()
            if try control.symbol(candidate.name, "XPEX_whole") {
                guard call == nil else { throw failure("Duplicate PEX call") }; call = candidate
            }
        }
        guard let definition, let call else { throw failure("Missing checked generated PEX source") }
        var count = 0
        for component in definition.body.components {
            try control.check()
            if component.type == .resistor, case .numeric(let value) = component.parameters["r"], value == 0 {
                guard value.bitPattern == 0 else { throw failure("Only exact positive-zero SPEF resistance declares a connection") }
                let next = count.addingReportingOverflow(1)
                guard !next.overflow else { throw failure("Connection count overflow") }; count = next.partialValue
            }
        }
        guard count > 0 else { return nil }
        guard count <= control.limits.maximumAssociations else { throw failure("Connection count exceeds admission") }
        let input = source.circuit
        let branchCount = input.branches.count.addingReportingOverflow(count)
        let sourceCount = flow.sources.count.addingReportingOverflow(count)
        guard !branchCount.overflow, !sourceCount.overflow else { throw failure("Connection capacity overflow") }
        let indexes = try PhysicalLogicWholeCandidateIndex(count: input.instances.count, control: control) { input.instances[$0].name }
        var bytes = UInt64(MemoryLayout<Self>.stride)
        // Admit the fixed stored payload rather than the size of the class reference.
        bytes = try PhysicalLogicWholeCandidateControl.sum(bytes, UInt64(MemoryLayout<PreparedSPICESimulation>.stride))
        bytes = try PhysicalLogicWholeCandidateControl.sum(bytes, UInt64(MemoryLayout<CircuitIR>.stride))
        bytes = try PhysicalLogicWholeCandidateControl.sum(bytes, UInt64(MemoryLayout<NativePrescribedVoltageFlowRequest>.stride))
        bytes = try PhysicalLogicWholeCandidateControl.sum(bytes, UInt64(MemoryLayout<SPICESourceStorageReservation>.stride))
        func array<T>(_ type: T.Type, _ count: Int) throws {
            bytes = try PhysicalLogicWholeCandidateControl.sum(bytes, UInt64(MemoryLayout<[T]>.stride))
            bytes = try PhysicalLogicWholeCandidateControl.sum(bytes,
                PhysicalLogicWholeCandidateControl.product(UInt64(count), UInt64(MemoryLayout<T>.stride)))
        }
        try array(Instance.self, input.instances.count); try array(Branch.self, branchCount.partialValue)
        try array(Row.self, count); try array(NativePrescribedVoltageFlowSource.self, sourceCount.partialValue)
        let individual = try PhysicalLogicWholeCandidateControl.sum(UInt64(MemoryLayout<[Branch]>.stride + MemoryLayout<Branch>.stride),
            UInt64(MemoryLayout<[String: ParameterValue]>.stride + MemoryLayout<(String, ParameterValue)>.stride))
        bytes = try PhysicalLogicWholeCandidateControl.sum(bytes, PhysicalLogicWholeCandidateControl.product(UInt64(count), individual))
        let storage = try control.reserve(bytes, kind: .liveOwnedBytes)
        try control.check()
        var branches: [Branch] = []; branches.reserveCapacity(branchCount.partialValue)
        var maximum = -1
        for branch in input.branches { try control.check(); branches.append(branch); maximum = max(maximum, branch.id) }
        var instances: [Instance] = []; instances.reserveCapacity(input.instances.count)
        for instance in input.instances { try control.check(); instances.append(instance) }
        var rows: [Row] = []; rows.reserveCapacity(count)
        var sources: [NativePrescribedVoltageFlowSource] = []; sources.reserveCapacity(sourceCount.partialValue)
        for law in flow.sources { try control.check(); sources.append(law) }
        for ordinal in definition.body.components.indices {
            try control.check()
            let component = definition.body.components[ordinal]
            guard component.type == .resistor, case .numeric(let value) = component.parameters["r"], value.bitPattern == 0 else { continue }
            let textBytes = try PhysicalLogicWholeCandidateControl.sum(UInt64(call.name.utf8.count),
                PhysicalLogicWholeCandidateControl.sum(1, UInt64(component.name.utf8.count)))
            let textLease = try control.reserve(textBytes)
            defer { withExtendedLifetime(textLease) {} }
            let name = call.name + "." + component.name
            guard let index = try indexes.find(name, control: control, key: { input.instances[$0].name }) else {
                throw failure("Declared connection is missing after lowering")
            }
            let original = input.instances[index]
            guard original.typeName == "resistor", original.nodes.count == 2, original.nodes[0] != original.nodes[1],
                  original.parameters.count == 1, case .real(let actual) = original.parameters["r"], actual.bitPattern == 0,
                  original.model == nil, original.mos == nil, original.diode == nil, original.osdi == nil,
                  original.ownedBranches.isEmpty, original.ownedNodes.isEmpty, original.referencedBranches.isEmpty,
                  original.referencedNodes.isEmpty, original.opticalNodes.isEmpty else { throw failure("Unsupported declared ideal-connection form") }
            for law in flow.sources {
                try control.check()
                guard law.deviceIndex != index else { throw failure("Caller cannot replace the declared connection law") }
            }
            let next = maximum.addingReportingOverflow(1)
            guard !next.overflow else { throw failure("Connection branch identity overflow") }; maximum = next.partialValue
            let branch = Branch(id: maximum)
            try control.check()
            instances[index] = .init(name: original.name, typeName: "vsource", nodes: original.nodes,
                parameters: ["v": .real(0)], ownedBranches: [branch])
            branches.append(branch); rows.append(.init(sourceOrdinal: ordinal, instanceIndex: index, branch: branch))
            sources.append(.init(deviceIndex: index, zeroVoltage: 0, oneVoltage: 0, timeOrigin: 0, timeScale: 1,
                initialNormalized: 0...0, normalized: 0...0, normalizedDerivativePerSecond: 0...0))
        }
        guard rows.count == count else { throw failure("Incomplete declared connection inventory") }
        try control.check()
        let circuit = CircuitIR(nodes: input.nodes, branches: branches, instances: instances, groundNode: input.groundNode,
            nodeNames: input.nodeNames, branchNames: input.branchNames, opticalNodes: input.opticalNodes,
            opticalConnections: input.opticalConnections, evaluationEnvironment: input.evaluationEnvironment)
        // Numerical proposals describe this FINAL circuit. Do not infer new current bounds or change hints.
        let request = NativePrescribedVoltageFlowRequest(originalLower: flow.originalLower, originalUpper: flow.originalUpper,
            startTime: flow.startTime, duration: flow.duration, sources: sources, algebraicRows: flow.algebraicRows,
            dynamicInitialCoordinates: flow.dynamicInitialCoordinates, initial: flow.initial, chargeBox: flow.chargeBox, window: flow.window)
        return Self(source: source, circuit: circuit, request: request, rows: rows, storage: storage)
    }
    func validate(_ fact: NativeVoltageSourceFact, control: PhysicalLogicWholeCandidateControl) throws -> Bool {
        for row in rows {
            try control.check()
            let original = source.circuit.instances[row.instanceIndex]
            guard try control.symbol(fact.instance.name, original.name) else { continue }
            guard fact.instance.typeName == "vsource", fact.instance.nodes == original.nodes,
                  fact.positiveNode == original.nodes[0], fact.negativeNode == original.nodes[1], fact.branch == row.branch,
                  fact.instance.ownedBranches.count == 1, fact.instance.ownedBranches[0] == row.branch, fact.dcVoltage.bitPattern == 0,
                  case .dc(let voltage) = fact.waveform, voltage.bitPattern == 0 else { throw Self.failure("Actual Native ideal-connection equation differs") }
            return true
        }
        return false
    }
    func validate(_ scopes: borrowing Span<NativePrescribedVoltageFlowSourceScope>,
        control: PhysicalLogicWholeCandidateControl) throws -> Int {
        var count = 0
        for scope in scopes {
            try control.check()
            guard try validate(scope.fact, control: control) else { continue }
            let law = scope.assumptions
            var matchedRow = false
            for row in rows {
                try control.check()
                if row.instanceIndex == scope.deviceIndex && row.branch == scope.fact.branch { matchedRow = true }
            }
            guard matchedRow,
                  law.deviceIndex == scope.deviceIndex, law.zeroVoltage.bitPattern == 0, law.oneVoltage.bitPattern == 0,
                  law.timeOrigin.bitPattern == 0, law.timeScale == 1, law.initialNormalized == 0...0,
                  law.normalized == 0...0, law.normalizedDerivativePerSecond == 0...0 else {
                throw Self.failure("Actual selected ideal-connection law differs")
            }
            count += 1
        }
        guard count == rows.count else { throw Self.failure("Incomplete selected ideal-connection inventory") }
        return count
    }
    private static func failure(_ message: String) -> PhysicalLogicWholeCandidateFlowFailure { .parasitics(message) }
}
