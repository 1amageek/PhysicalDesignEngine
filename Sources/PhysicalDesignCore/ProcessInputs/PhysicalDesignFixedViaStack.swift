import LEF
import PDKCore

/// Classifies fixed source shapes without assigning meaning to VIA LAYER order.
struct PhysicalDesignFixedViaStack {
    let lowerLayer: Int16
    let cutLayer: Int16
    let upperLayer: Int16

    init(via: LEFViaDef, layerMap: [String: Int16], layers: [Int16: PDKLayerDefinition],
         sourceLayers: [Int16: LEFLayerDef]) throws {
        guard via.layers.count == 3 else {
            throw PhysicalDesignTechnologyError.invalid("Fixed VIA \(via.name) requires exactly three distinct typed source layers.")
        }
        var routing: [Int16] = []
        var cut: Int16?
        var seen: Set<Int16> = []
        for layer in via.layers {
            guard let number = layerMap[layer.layerName], seen.insert(number).inserted,
                  let definition = layers[number], let source = sourceLayers[number] else {
                throw PhysicalDesignTechnologyError.invalid("Fixed VIA \(via.name) requires distinct mapped canonical layer declarations.")
            }
            switch source.type {
            case .routing where definition.isRoutingLayer:
                routing.append(number)
            case .cut where !definition.isRoutingLayer && (definition.purpose == .via || definition.purpose == .contact):
                guard cut == nil else {
                    throw PhysicalDesignTechnologyError.invalid("Fixed VIA \(via.name) has more than one CUT layer.")
                }
                cut = number
            default:
                throw PhysicalDesignTechnologyError.invalid("Fixed VIA \(via.name) has contradictory source and manifest layer roles.")
            }
        }
        guard routing.count == 2, let cut, routing[0] != routing[1] else {
            throw PhysicalDesignTechnologyError.invalid("Fixed VIA \(via.name) requires two ROUTING layers and one CUT layer.")
        }
        lowerLayer = min(routing[0], routing[1])
        upperLayer = max(routing[0], routing[1])
        cutLayer = cut
    }
}
