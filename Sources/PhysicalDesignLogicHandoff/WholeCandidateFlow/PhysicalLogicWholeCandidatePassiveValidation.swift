import CoreSpice
import CoreSpiceIO
import PEXCore

/// Transfers the exact cold decoded passive semantics to the actual lowered full circuit.
internal enum PhysicalLogicWholeCandidatePassiveValidation {
    static func validate(source: PreparedSPICESimulation, cold: ParasiticIR,
        control: PhysicalLogicWholeCandidateControl) throws {
        var definition: ParsedSubcircuit?, call: ParsedComponent?
        for item in source.netlist.subcircuits {
            try control.check()
            if try control.symbol(item.name, "whole_pex") {
                guard definition == nil else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Duplicate generated PEX declaration") }
                definition = item
            }
        }
        for item in source.netlist.components {
            try control.check()
            if try control.symbol(item.name, "XPEX_whole") {
                guard call == nil else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Duplicate generated PEX call") }
                call = item
            }
        }
        guard let definition, let call, let model = call.modelName,
              try control.symbol(model, definition.name), definition.ports.count == call.nodes.count,
              definition.body.components.count == cold.elements.count else {
            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Generated PEX inventory differs after lowering")
        }
        let coldIndex = try PhysicalLogicWholeCandidateIndex(count: cold.elements.count, control: control) { cold.elements[$0].id }
        let instanceIndex = try PhysicalLogicWholeCandidateIndex(count: source.circuit.instances.count, control: control) { source.circuit.instances[$0].name }
        let ports = try PhysicalLogicWholeCandidateIndex(count: definition.ports.count, control: control) { definition.ports[$0] }
        for component in definition.body.components {
            try control.check()
            let parameter: String
            switch component.type {
            case .resistor: parameter = "r"
            case .capacitor: parameter = "c"
            default: throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Unsupported generated passive kind")
            }
            let byteCount = try PhysicalLogicWholeCandidateControl.sum(
                UInt64(call.name.utf8.count), PhysicalLogicWholeCandidateControl.sum(1, UInt64(component.name.utf8.count)))
            let nameLease = try control.reserve(byteCount)
            defer { withExtendedLifetime(nameLease) {} }
            let fullName = call.name + "." + component.name
            guard let flat = try instanceIndex.find(fullName, control: control, key: { source.circuit.instances[$0].name }),
                  let decoded = try coldIndex.find(component.name, control: control, key: { cold.elements[$0].id }) else {
                throw PhysicalLogicWholeCandidateFlowFailure.parasitics("A generated passive disappeared")
            }
            let actual = source.circuit.instances[flat], expected = cold.elements[decoded]
            guard case .numeric(let represented) = component.parameters[parameter],
                  case .real(let value) = actual.parameters[parameter],
                  represented.bitPattern == value.bitPattern, expected.value.bitPattern == value.bitPattern,
                  (parameter == "r" ? expected.kind == .resistor : (expected.kind == .capacitor || expected.kind == .coupling)),
                  actual.typeName == (parameter == "r" ? "resistor" : "capacitor"),
                  component.nodes.count == 2, actual.nodes.count == 2 else {
                throw PhysicalLogicWholeCandidateFlowFailure.parasitics("A generated passive changed kind or value bits")
            }
            for terminal in 0..<2 {
                try control.check()
                let raw = component.nodes[terminal]
                if raw.isGround {
                    guard actual.nodes[terminal] == .ground else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Ground passive endpoint differs") }
                    continue
                }
                let mapped: String
                let mappedLease: SPICESourceStorageReservation?
                if let port = try ports.find(raw.name, control: control, key: { definition.ports[$0] }) {
                    mapped = call.nodes[port].name; mappedLease = nil
                } else {
                    let bytes = try PhysicalLogicWholeCandidateControl.sum(UInt64(call.name.utf8.count),
                        PhysicalLogicWholeCandidateControl.sum(1, UInt64(raw.name.utf8.count)))
                    mappedLease = try control.reserve(bytes)
                    mapped = call.name + "." + raw.name
                }
                defer { withExtendedLifetime(mappedLease) {} }
                guard let loweredName = source.circuit.nodeNames[actual.nodes[terminal]],
                      try control.symbol(loweredName, mapped) else {
                    throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Distributed passive endpoint differs")
                }
            }
        }
    }
}
