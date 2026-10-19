import CircuiteFoundation
import LEF
import PDKCore

/// Retains supported source facts; NativeDRC owns numerical measurement and connectivity.
struct PhysicalDesignAntennaSourceProjection: Sendable {
    enum Basis: Sendable, Equatable { case surface, sidewall, cutArea }
    enum DiffusionOrigin: Sendable, Equatable { case explicit, omittedUnqualifiedZero }
    enum GateCoverage: Sendable, Equatable { case reportedPositive, missingRequiredGate, notRequired }
    struct Point: Sendable {
        let diffusionAreaSquareMicrons: Double
        let ratio: Double
    }
    enum RatioValue: Sendable {
        case scalar(Double)
        case piecewiseLinear([Point])
    }
    struct Layer: Sendable {
        let layerID: String
        let sourceName: String
        let fabricationRank: Int
        let sourceLayerIndex: Int
        let source: ArtifactReference
        let isCut: Bool
    }
    struct LayerLaw: Sendable {
        let layerID: String
        let sourceName: String
        let fabricationRank: Int
        let sourceStatementIndex: Int
        let source: ArtifactReference
        let explicitOxide1: Bool
        let basis: Basis
        let thicknessMicrons: Double?
        let ratio: RatioValue
    }
    struct Terminal: Sendable {
        let masterName: String
        let pinName: String
        let source: ArtifactReference
        let rawGateAreaSquareMicrons: Double?
        let rawDiffusionAreaSquareMicrons: Double?
        let reportedDiffusionAreaSquareMicrons: Double
        let diffusionOrigin: DiffusionOrigin
        let gateCoverage: GateCoverage
    }
    let manifestReference: ArtifactReference
    let sources: [String: ArtifactReference]
    let layers: [Layer]
    let laws: [LayerLaw]
    let terminals: [Terminal]
    let recordCount: Int

    init(inputs: PhysicalDesignProcessInputs, manifestReference: ArtifactReference,
         sources: [String: ArtifactReference], maximumRecords: Int) throws {
        try Self.validateSupported(inputs: inputs)
        guard inputs.hasSourceAntennaLaws else {
            throw PhysicalDesignTechnologyError.unsupported("Source antenna measurement requires retained source laws.")
        }
        guard maximumRecords > 0, manifestReference.digest.algorithm == .sha256,
              Set(sources.keys) == Set(inputs.technologyViews.keys).union(inputs.cellViews.keys) else {
            throw PhysicalDesignTechnologyError.invalid("Antenna source projection requires exact selected sources and a positive record ceiling.")
        }
        for (id, reference) in sources {
            let assets = inputs.manifest.assets.filter { $0.assetID == id }
            guard assets.count == 1, let asset = assets.first, asset.format == .lef,
                  asset.role == (inputs.technologyViews[id] == nil ? .cell : .technology),
                  reference.digest.algorithm == .sha256,
                  asset.sha256?.lowercased() == reference.digest.hexadecimalValue,
                  asset.byteCount.flatMap(UInt64.init(exactly:)) == reference.byteCount else {
                throw PhysicalDesignTechnologyError.invalid("Antenna source reference does not match its exact manifest asset.")
            }
        }
        var count = 0
        func admit() throws {
            try Task.checkCancellation()
            guard count < maximumRecords else {
                throw PhysicalDesignTechnologyError.invalid("Antenna source projection record ceiling exhausted.")
            }
            count += 1
        }
        var layers: [Layer] = [], laws: [LayerLaw] = [], terminals: [Terminal] = []
        for id in inputs.technologyViews.keys.sorted() {
            guard let document = inputs.technologyViews[id], let reference = sources[id] else {
                throw PhysicalDesignTechnologyError.invalid("Antenna technology source disappeared.")
            }
            for (sourceIndex, layer) in document.layers.enumerated() where layer.type == .routing || layer.type == .cut {
                try admit()
                let mapped = try Self.mapped(layer, assetID: id, manifest: inputs.manifest)
                let rank = layers.count
                layers.append(.init(layerID: mapped.layerID, sourceName: layer.name, fabricationRank: rank,
                    sourceLayerIndex: sourceIndex, source: reference, isCut: layer.type == .cut))
                var explicitOxide1 = false
                var surface: LayerLaw?, sidewall: LayerLaw?
                for (index, statement) in layer.antennaStatements.enumerated() {
                    try admit()
                    switch statement {
                    case .model: explicitOxide1 = true
                    case .ratio(let kind, let value):
                        let ratio: RatioValue
                        switch value {
                        case .scalar(let number): ratio = .scalar(number)
                        case .piecewiseLinear(let points):
                            var retained: [Point] = []
                            for point in points {
                                try admit()
                                retained.append(.init(diffusionAreaSquareMicrons: point.diffusionAreaSquareMicrons, ratio: point.ratio))
                            }
                            ratio = .piecewiseLinear(retained)
                        }
                        let law = LayerLaw(layerID: mapped.layerID, sourceName: layer.name, fabricationRank: rank,
                            sourceStatementIndex: index, source: reference, explicitOxide1: explicitOxide1,
                            basis: kind == .diffusionSideArea ? .sidewall : (layer.type == .cut ? .cutArea : .surface),
                            thicknessMicrons: kind == .diffusionSideArea ? layer.thickness : nil, ratio: ratio)
                        if kind == .diffusionSideArea { sidewall = law } else { surface = law }
                    }
                }
                if let surface { try admit(); laws.append(surface) }
                if let sidewall { try admit(); laws.append(sidewall) }
            }
        }
        var masters: Set<String> = []
        let documents = inputs.technologyViews.merging(inputs.cellViews) { first, _ in first }
        for id in documents.keys.sorted() {
            guard let document = documents[id], let reference = sources[id] else {
                throw PhysicalDesignTechnologyError.invalid("Antenna cell source disappeared.")
            }
            for master in document.macros {
                try admit()
                guard masters.insert(master.name).inserted else {
                    throw PhysicalDesignTechnologyError.invalid("Antenna master identity is ambiguous.")
                }
                for pin in master.pins {
                    try admit()
                    let positive = (pin.antennaGateArea ?? 0) > 0
                    let coverage: GateCoverage = positive ? .reportedPositive : (pin.direction == .input ? .missingRequiredGate : .notRequired)
                    terminals.append(.init(masterName: master.name, pinName: pin.name, source: reference,
                        rawGateAreaSquareMicrons: pin.antennaGateArea, rawDiffusionAreaSquareMicrons: pin.antennaDiffArea,
                        reportedDiffusionAreaSquareMicrons: pin.antennaDiffArea ?? 0,
                        diffusionOrigin: pin.antennaDiffArea == nil ? .omittedUnqualifiedZero : .explicit,
                        gateCoverage: coverage))
                }
            }
        }
        self.manifestReference = manifestReference; self.sources = sources
        self.layers = layers; self.laws = laws; self.terminals = terminals; recordCount = count
    }

    static func validateSupported(inputs: PhysicalDesignProcessInputs) throws {
        guard inputs.hasSourceAntennaLaws else { return }
        guard Set(inputs.technologyViews.keys).isDisjoint(with: Set(inputs.cellViews.keys)) else {
            throw PhysicalDesignTechnologyError.invalid("Antenna source roles must be disjoint.")
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Native process intake supports one technology source, OXIDE1 scalar/PWL laws and unqualified PIN areas only. Other retained source abstractions must remain unsupported until their exact projection and numerical consumer are implemented and verified.
        guard inputs.technologyViews.count == 1,
              inputs.cellViews.values.allSatisfy({ $0.layers.allSatisfy { $0.antennaStatements.isEmpty } }) else {
            throw PhysicalDesignTechnologyError.unsupported("Native antenna statements require one technology-role source and no cell-role laws.")
        }
        for (id, document) in inputs.technologyViews {
            var mappedIDs: Set<String> = []
            for layer in document.layers {
                try Task.checkCancellation()
                if layer.type == .routing || layer.type == .cut {
                    let mapped = try mapped(layer, assetID: id, manifest: inputs.manifest)
                    guard mappedIDs.insert(mapped.layerID).inserted else {
                        throw PhysicalDesignTechnologyError.invalid("Antenna fabrication layer identity is ambiguous.")
                    }
                } else if !layer.antennaStatements.isEmpty {
                    throw PhysicalDesignTechnologyError.unsupported("Native antenna statements require ROUTING or CUT layers.")
                }
                for statement in layer.antennaStatements {
                    switch statement {
                    case .model(let oxide):
                        guard oxide == .oxide1 else { throw PhysicalDesignTechnologyError.unsupported("Native antenna statements support OXIDE1 only.") }
                    case .ratio(let kind, let value):
                        if kind == .diffusionSideArea {
                            guard layer.type == .routing, let thickness = layer.thickness,
                                  thickness.isFinite, thickness > 0 else {
                                throw PhysicalDesignTechnologyError.unsupported("Native antenna side-area statements require exact positive routing THICKNESS.")
                            }
                        }
                        switch value {
                        case .scalar(let ratio): try validateNumber(ratio)
                        case .piecewiseLinear(let points):
                            guard points.count >= 2 else { throw PhysicalDesignTechnologyError.invalid("Antenna PWL requires two source points.") }
                            var previous: Double?
                            for point in points {
                                try Task.checkCancellation()
                                try validateNumber(point.diffusionAreaSquareMicrons); try validateNumber(point.ratio)
                                guard previous.map({ point.diffusionAreaSquareMicrons > $0 }) ?? true else {
                                    throw PhysicalDesignTechnologyError.invalid("Antenna PWL source diffusion coordinates must strictly increase.")
                                }
                                previous = point.diffusionAreaSquareMicrons
                            }
                        }
                    }
                }
            }
        }
        let documents = inputs.technologyViews.merging(inputs.cellViews) { first, _ in first }
        for document in documents.values {
            for master in document.macros {
                guard !master.name.isEmpty else { throw PhysicalDesignTechnologyError.invalid("Antenna master requires an exact source name.") }
                var pins: Set<String> = []
                for pin in master.pins {
                    try Task.checkCancellation()
                    guard !pin.name.isEmpty, pins.insert(pin.name).inserted else { throw PhysicalDesignTechnologyError.invalid("Antenna pin identity is empty or ambiguous.") }
                    guard pin.antennaModel == nil, pin.direction != nil else {
                        throw PhysicalDesignTechnologyError.unsupported("Native antenna PIN facts require complete unqualified scalar coverage and a source direction.")
                    }
                    if let gate = pin.antennaGateArea { try validateNumber(gate) }
                    if let diffusion = pin.antennaDiffArea { try validateNumber(diffusion) }
                }
            }
        }
    }

    private static func validateNumber(_ value: Double) throws {
        guard value.isFinite, value >= 0 else { throw PhysicalDesignTechnologyError.invalid("Antenna source values must be finite and nonnegative.") }
    }

    private static func mapped(_ layer: LEFLayerDef, assetID: String, manifest: PDKManifest) throws -> PDKLayerDefinition {
        let ids = Set(manifest.crossViewMappings.filter { $0.assetID == assetID && $0.view == .lef }.flatMap(\.layerIDs))
        let matches = manifest.layers.filter { ids.contains($0.layerID) && ($0.name == layer.name || $0.aliases.contains(layer.name)) }
        guard matches.count == 1, let mapped = matches.first,
              (layer.type == .routing && mapped.isRoutingLayer)
                || (layer.type == .cut && !mapped.isRoutingLayer && (mapped.purpose == .via || mapped.purpose == .contact)) else {
            throw PhysicalDesignTechnologyError.unsupported("Native antenna statements require one exact compatible source layer mapping for \(layer.name).")
        }
        return mapped
    }
}
