import PEXCore

/// Associates every canonical physical terminal without replacing extracted internal nodes.
internal enum PhysicalLogicWholeCandidatePEXMembership {
    static func validate(_ ir: ParasiticIR, assessment: PhysicalLogicECOAssessment,
        request: PhysicalLogicWholeCandidateFlowRequest, control: PhysicalLogicWholeCandidateControl) throws {
        guard ir.units == .canonical, ir.cornerID == request.pexCorner,
              ir.elements.count <= control.limits.maximumAssociations else {
            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Noncanonical or oversized PEX input")
        }
        let pins = assessment.candidate.pins
        let lease = try control.slots(Int.self, count: pins.count)
        defer { withExtendedLifetime(lease) {} }
        try control.check(UInt64(pins.count))
        var counts = [Int](repeating: 0, count: pins.count)
        for net in ir.nets {
            try control.text(net.name.value)
            for node in net.nodes {
                try control.check()
                if node.kind == .internal { continue }
                guard node.kind == .pin else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Unknown extracted node role") }
                var matches = 0
                for index in pins.indices {
                    try control.check()
                    let pin = pins[index]
                    if let name = request.pinNodes[pin.id], try control.same(name, node.name.value) {
                        guard pin.netID == net.name.value, pin.cellID == node.instancePath?.value else {
                            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Extracted terminal owner or net differs from the physical correspondence")
                        }
                        counts[index] += 1; matches += 1
                    }
                }
                guard matches == 1 else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Unassociated extracted terminal") }
            }
        }
        for count in counts { try control.check(); guard count == 1 else { throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Missing or duplicate extracted physical pin") } }
        for element in ir.elements {
            try control.check()
            guard element.value.isFinite, element.value >= 0,
                  element.kind == .resistor || element.kind == .capacitor || element.kind == .coupling else {
                throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Unsupported extracted element")
            }
        }
    }
}
