import CircuiteFoundation
import DEF
import LEF
import LayoutIR
import MaskGeometry
import PDKCore

struct PhysicalDesignProcessGeometry: Sendable {
    struct Pin: Sendable {
        let definition: LEFPinDef
        let shapes: [IRBoundary]
    }
    struct Master: Sendable {
        let definition: LEFMacroDef
        let width: Int64
        let height: Int64
        let origin: IRPoint
        let pins: [String: Pin]
        let obstructions: [IRBoundary]
    }
    struct Site: Sendable {
        let definition: LEFSiteDef
        let width: Int64
        let height: Int64
    }
    struct Via: Sendable {
        let definition: LEFViaDef
        let lowerLayer: Int16
        let cutLayer: Int16
        let upperLayer: Int16
        let shapes: [IRBoundary]
    }

    let obstructionSpacingUsesMinimumWidth: Bool
    let obstructionSpacingWidths: [Int16: Int64]
    let unitsPerMicron: Int
    let manufacturingGrid: PhysicalDesignManufacturingGrid
    let manifestReference: ArtifactReference
    let sources: [String: ArtifactReference]
    let masters: [String: Master]
    let sites: [String: Site]
    let vias: [String: Via]
    let layers: [Int16: PDKLayerDefinition]
    let sourceLayers: [Int16: LEFLayerDef]
    let cutSpacings: [Int16: Int32]
    let routingMinimumAreas: [Int16: PhysicalDesignRoutingAreaRule]
    let minimumHoleAreas: [Int16: UInt64]
    let maximumHoleGeometryChecks: Int?
    let routingSpacingRules: [Int16: PhysicalDesignRoutingSpacingRule]

    var allowsUnqualifiedSiteRows: Bool { !minimumHoleAreas.isEmpty && masters.isEmpty && sites.isEmpty }

    init(inputs: PhysicalDesignProcessInputs, request: PhysicalDesignRequest, units: Int) throws {
        _ = try inputs.databaseUnitsPerMicron(for: units)
        try inputs.validatePropertyCapabilities()
        try inputs.validateAntennaCapabilities()
        try inputs.validateEnclosureCapabilities(request: request)
        let minimumObstructions = try inputs.obstructionSpacingUsesMinimumWidth()
        obstructionSpacingUsesMinimumWidth = minimumObstructions
        unitsPerMicron = units
        manufacturingGrid = try .init(inputs: inputs, units: units)
        manifestReference = request.pdk.manifest
        sources = request.processAssets.mapValues(\.reference)
        guard Set(inputs.technologyViews.keys).isDisjoint(with: Set(inputs.cellViews.keys)) else {
            throw PhysicalDesignTechnologyError.invalid("A process asset cannot have two source roles.")
        }
        let documents = inputs.technologyViews.merging(inputs.cellViews) { first, _ in first }
        guard Set(documents.keys) == Set(sources.keys) else {
            throw PhysicalDesignTechnologyError.invalid("Projected sources must match the admitted asset map.")
        }
        var layerMaps: [String: [String: Int16]] = [:]
        var nativeLayers: [Int16: PDKLayerDefinition] = [:]
        for assetID in documents.keys.sorted() {
            let ids = Set(inputs.manifest.crossViewMappings.filter { $0.assetID == assetID && $0.view == .lef }.flatMap(\.layerIDs))
            var names: [String: Int16] = [:]
            for id in ids.sorted() {
                let definitions = inputs.manifest.layers.filter { $0.layerID == id }
                guard definitions.count == 1, let definition = definitions.first,
                      let number = Int16(exactly: definition.number), number > 0 else {
                    throw PhysicalDesignTechnologyError.invalid("Mapped layer \(id) requires one positive native layer number.")
                }
                if let previous = nativeLayers[number], previous != definition {
                    throw PhysicalDesignTechnologyError.invalid("Native layer \(number) has contradictory process definitions.")
                }
                nativeLayers[number] = definition
                for name in Set([definition.name] + definition.aliases) {
                    guard !name.isEmpty, names[name] == nil || names[name] == number else {
                        throw PhysicalDesignTechnologyError.invalid("Layer name \(name) is ambiguous in source \(assetID).")
                    }
                    names[name] = number
                }
            }
            layerMaps[assetID] = names
        }
        var declaredLayers: [Int16: LEFLayerDef] = [:]
        for assetID in inputs.technologyViews.keys.sorted() {
            guard let document = inputs.technologyViews[assetID], let mapping = layerMaps[assetID] else {
                throw PhysicalDesignTechnologyError.invalid("An admitted technology view became unavailable.")
            }
            for layer in document.layers {
                guard let number = mapping[layer.name] else { continue }
                guard declaredLayers[number] == nil, let definition = nativeLayers[number],
                      (layer.type == .routing && definition.isRoutingLayer)
                        || (layer.type == .cut && !definition.isRoutingLayer && (definition.purpose == .via || definition.purpose == .contact))
                        || (layer.type != .routing && layer.type != .cut && !definition.isRoutingLayer) else {
                    throw PhysicalDesignTechnologyError.invalid("Layer \(layer.name) has ambiguous or contradictory standard/process semantics.")
                }
                declaredLayers[number] = layer
            }
        }
        layers = nativeLayers
        sourceLayers = declaredLayers
        var compiledSpacing: [Int16: PhysicalDesignRoutingSpacingRule] = [:]
        for (number, source) in declaredLayers where source.type == .routing && (source.spacing != nil || source.spacingTable != nil) {
            compiledSpacing[number] = try PhysicalDesignRoutingSpacingRule(source: source, units: units)
        }
        routingSpacingRules = compiledSpacing
        var obstructionWidths: [Int16: Int64] = [:]
        if minimumObstructions {
            for (number, source) in declaredLayers where compiledSpacing[number]?.usesParallelRunLength == true {
                if let width = source.minwidth ?? source.width {
                    obstructionWidths[number] = try PhysicalDesignProcessInputs.dbu(width, units: units,
                        field: "\(source.name) minimum width for USEMINSPACING OBS", positive: true)
                }
            }
        }
        obstructionSpacingWidths = obstructionWidths
        var areas: [Int16: PhysicalDesignRoutingAreaRule] = [:]
        for (number, source) in declaredLayers where source.type == .routing {
            if let area = source.area { areas[number] = try .init(areaMicronsSquared: area, unitsPerMicron: units) }
        }
        routingMinimumAreas = areas
        maximumHoleGeometryChecks = request.configuration.maximumRoutingCandidateChecks
        var holeAreas: [Int16: UInt64] = [:]
        for assetID in documents.keys.sorted() {
            guard let document = documents[assetID], let mapping = layerMaps[assetID] else {
                throw PhysicalDesignTechnologyError.invalid("MINENCLOSEDAREA source context disappeared.")
            }
            for source in document.layers where !source.minimumEnclosedAreas.isEmpty {
                guard source.type == .routing, source.minimumEnclosedAreas.count == 1,
                      let layer = mapping[source.name], let canonical = declaredLayers[layer],
                      canonical.minimumEnclosedAreas == source.minimumEnclosedAreas,
                      let area = source.minimumEnclosedAreas.first else {
                    throw PhysicalDesignTechnologyError.unsupported("MINENCLOSEDAREA requires one mapped canonical ROUTING source law on \(source.name).")
                }
                do { holeAreas[layer] = try PhysicalDesignRoutingAreaRule(areaMicronsSquared: area, unitsPerMicron: units).minimumDBU2 }
                catch { throw PhysicalDesignTechnologyError.invalid("MINENCLOSEDAREA threshold: \(error.localizedDescription)") }
            }
        }
        minimumHoleAreas = holeAreas
        cutSpacings = try declaredLayers.filter { $0.value.type == .cut }.compactMapValues { rule in
            guard let spacing = rule.spacing else { return nil }
            return try Self.coordinate(PhysicalDesignProcessInputs.dbu(spacing, units: units, field: "\(rule.name).SPACING"), field: "cut spacing")
        }
        var nativeSites: [String: Site] = [:]
        var nativeVias: [String: Via] = [:]
        for assetID in documents.keys.sorted() {
            guard let document = documents[assetID], let layerMap = layerMaps[assetID] else {
                throw PhysicalDesignTechnologyError.invalid("An admitted source view became unavailable.")
            }
            for site in document.sites {
                guard nativeSites[site.name] == nil else { throw PhysicalDesignTechnologyError.invalid("Site \(site.name) is ambiguous.") }
                nativeSites[site.name] = Site(definition: site,
                    width: try Self.dimension(site.width, units: units, field: "\(site.name).SIZE width"),
                    height: try Self.dimension(site.height, units: units, field: "\(site.name).SIZE height"))
            }
            for via in document.vias {
                // FIXME(INCOMPLETE_IMPLEMENTATION): Native process projection currently resolves fixed VIA shapes only. API/CLI generated-via requests must fail until the complete VIARULE parameters and generated cut/enclosure geometry are retained and verified.
                guard !via.isGenerate, via.viaRule == nil, via.cutSize == nil, via.cutSpacing == nil,
                      via.enclosure == nil, via.rowCol == nil else {
                    throw PhysicalDesignTechnologyError.unsupported("Generated via \(via.name) requires complete native rule materialization.")
                }
                guard nativeVias[via.name] == nil else { throw PhysicalDesignTechnologyError.invalid("Fixed VIA \(via.name) is ambiguous.") }
                let stack = try PhysicalDesignFixedViaStack(via: via, layerMap: layerMap, layers: nativeLayers, sourceLayers: declaredLayers)
                let lower = stack.lowerLayer, cut = stack.cutLayer, upper = stack.upperLayer
                if let resistance = via.resistance, !resistance.isFinite || resistance < 0 {
                    throw PhysicalDesignTechnologyError.invalid("Via \(via.name) resistance must be finite and nonnegative.")
                }
                var shapes: [IRBoundary] = []
                for layer in via.layers {
                    shapes += try Self.shapes(rectangles: layer.rects, polygons: layer.polygons,
                        layer: Self.layer(layer.layerName, in: layerMap), units: units)
                }
                let cutShapes = shapes.filter { $0.layer == cut }
                guard let rule = declaredLayers[cut] else { throw PhysicalDesignTechnologyError.invalid("Fixed via cut rules disappeared.") }
                try Self.validateCutSpacing(cutShapes, minimum: cutSpacings[cut])
                if let width = rule.width {
                    let minimum = try Self.coordinate(Self.dimension(width, units: units, field: "\(rule.name).WIDTH"), field: "cut width")
                    for shape in cutShapes {
                        guard try Region(layer: cut, polygons: [shape]).widthViolations(minWidth: minimum).isEmpty else {
                            throw PhysicalDesignTechnologyError.invalid("Via \(via.name) violates the declared cut WIDTH.")
                        }
                    }
                }
                if rule.enclosures.contains(where: { $0.side != nil }) {
                    try Self.validateQualifiedEnclosureStack(cutLayer: cut, lowerLayer: lower, upperLayer: upper,
                        inputs: inputs, layerMaps: layerMaps)
                }
                for metalLayer in [lower, upper] {
                    let enclosures = try rule.enclosures.filter {
                        $0.side == nil || (metalLayer == lower ? $0.side == .below : $0.side == .above)
                    }.map { value in
                        (try PhysicalDesignProcessInputs.dbu(value.overhang1, units: units, field: "enclosure overhang1"),
                         try PhysicalDesignProcessInputs.dbu(value.overhang2, units: units, field: "enclosure overhang2"))
                    }
                    let metal = Region(layer: metalLayer, polygons: shapes.filter { $0.layer == metalLayer })
                    for shape in cutShapes {
                        try Self.validateContact(shape, metal: metal, enclosures: enclosures)
                    }
                }
                nativeVias[via.name] = Via(definition: via, lowerLayer: lower, cutLayer: cut, upperLayer: upper, shapes: shapes)
            }
        }
        sites = nativeSites
        vias = nativeVias
        let dimensionLookup = PhysicalDesignMasterGeometry(inputs.cellViews.values.flatMap(\.macros))
        var nativeMasters: [String: Master] = [:]
        for assetID in inputs.cellViews.keys.sorted() {
            guard let document = inputs.cellViews[assetID], !document.macros.isEmpty, let layerMap = layerMaps[assetID] else {
                throw PhysicalDesignTechnologyError.invalid("Cell source \(assetID) requires declared masters.")
            }
            let mappedNames = Set(inputs.manifest.crossViewMappings.filter { $0.assetID == assetID && $0.view == .lef }.flatMap(\.physicalNames))
            for master in document.macros {
                guard mappedNames.contains(master.name), nativeMasters[master.name] == nil else {
                    throw PhysicalDesignTechnologyError.invalid("Master \(master.name) requires one explicitly mapped source declaration.")
                }
                let size = try dimensionLookup.dimensions(of: master.name, units: units)
                _ = try Self.coordinate(size.width, field: "master width")
                _ = try Self.coordinate(size.height, field: "master height")
                if let site = master.site, nativeSites[site] == nil {
                    throw PhysicalDesignTechnologyError.invalid("Master \(master.name) references missing site \(site).")
                }
                var pins: [String: Pin] = [:]
                for pin in master.pins {
                    guard pins[pin.name] == nil else { throw PhysicalDesignTechnologyError.invalid("Master \(master.name) pin \(pin.name) is ambiguous.") }
                    pins[pin.name] = Pin(definition: pin, shapes: try Self.portShapes(pin.ports, layerMap: layerMap, vias: nativeVias, units: units))
                }
                nativeMasters[master.name] = Master(definition: master, width: size.width, height: size.height,
                    origin: try Self.point(master.origin ?? .init(x: 0, y: 0), units: units), pins: pins,
                    obstructions: try Self.portShapes(master.obs, layerMap: layerMap, vias: nativeVias, units: units, allowEmpty: true))
            }
        }
        masters = nativeMasters
        for (name, site) in sites {
            try manufacturingGrid.validate(site.width, field: "site \(name) width")
            try manufacturingGrid.validate(site.height, field: "site \(name) height")
        }
        for (name, via) in vias {
            for shape in via.shapes { try manufacturingGrid.validate(shape, field: "via \(name)") }
        }
        for (name, master) in masters {
            for value in [master.width, master.height, Int64(master.origin.x), Int64(master.origin.y)] {
                try manufacturingGrid.validate(value, field: "master \(name)")
            }
            for shape in master.obstructions { try manufacturingGrid.validate(shape, field: "OBS \(name)") }
            for pin in master.pins.values {
                for shape in pin.shapes { try manufacturingGrid.validate(shape, field: "PORT \(name)/\(pin.definition.name)") }
            }
        }
    }

    func pinShapes(master name: String, pin: String, orientation: DEFOrientation, x: Int64, y: Int64) throws -> [IRBoundary] {
        let master = try requireMaster(name)
        guard let pin = master.pins[pin] else { throw PhysicalDesignTechnologyError.invalid("Master \(name) has no declared pin \(pin).") }
        return try transform(pin.shapes, master: master, orientation: orientation, x: x, y: y)
    }

    // FIXME(INCOMPLETE_IMPLEMENTATION): Native DEF intake and master replacement select a declared routing-boundary reference point. Width-aware track access and route closure must be established before this point can qualify native routing.
    func referencePin(_ pin: PhysicalDesignSnapshot.Pin, for cell: PhysicalDesignSnapshot.Cell) throws -> PhysicalDesignSnapshot.Pin {
        let master = try requireMaster(cell.master)
        guard pin.cellID == cell.id, let direction = master.pins[pin.name]?.definition.direction else {
            throw PhysicalDesignTechnologyError.invalid("Connected pin \(pin.id) requires an exact declared master port and direction.")
        }
        let shapes = try pinShapes(master: cell.master, pin: pin.name, orientation: cell.orientation, x: cell.x, y: cell.y)
        guard let shape = shapes.first(where: { layers[$0.layer]?.isRoutingLayer == true }), let point = shape.points.first else {
            throw PhysicalDesignTechnologyError.invalid("Connected pin \(pin.id) requires declared routing geometry.")
        }
        var resolved = pin
        resolved.x = Int64(point.x)
        resolved.y = Int64(point.y)
        resolved.direction = direction.rawValue.lowercased()
        resolved.accessLayer = Int(shape.layer)
        return resolved
    }

    func obstructionShapes(master name: String, orientation: DEFOrientation, x: Int64, y: Int64) throws -> [IRBoundary] {
        let master = try requireMaster(name)
        return try transform(master.obstructions, master: master, orientation: orientation, x: x, y: y)
    }

    func requireMaster(_ name: String) throws -> Master {
        guard let master = masters[name] else { throw PhysicalDesignTechnologyError.invalid("Master \(name) is absent from the selected process views.") }
        return master
    }

    func bufferPorts(master name: String) throws -> (input: String, output: String) {
        let ports = try requireMaster(name).pins.values.filter { $0.definition.use != .power && $0.definition.use != .ground }
        let inputs = ports.filter { $0.definition.direction == .input }
        let outputs = ports.filter { $0.definition.direction == .output }
        guard ports.count == 2, inputs.count == 1, outputs.count == 1,
              ports.allSatisfy({ $0.definition.use == nil || $0.definition.use == .signal || $0.definition.use == .clock }) else {
            throw PhysicalDesignTechnologyError.unsupported("Buffer master \(name) requires one declared input and one output signal/clock port.")
        }
        return (inputs[0].definition.name, outputs[0].definition.name)
    }

    func dimensions(master name: String, orientation: DEFOrientation) throws -> (width: Int64, height: Int64) {
        let master = try requireMaster(name)
        let rotated = [DEFOrientation.e, .w, .fe, .fw].contains(orientation)
        return rotated ? (master.height, master.width) : (master.width, master.height)
    }

    func viaShapes(master name: String, x: Int64, y: Int64) throws -> [IRBoundary] {
        guard let via = vias[name] else { throw PhysicalDesignTechnologyError.invalid("Fixed via \(name) is absent from the selected process views.") }
        return try via.shapes.map { shape in
            var translated = shape
            translated.points = try shape.points.map { try Self.translated(Int64($0.x), Int64($0.y), x: x, y: y) }
            return translated
        }
    }

    func viaFits(_ via: PhysicalDesignSnapshot.Via, within bounds: PhysicalDesignSnapshot.Rect) throws -> Bool {
        guard let name = via.master else { throw PhysicalDesignTechnologyError.invalid("Via footprint admission requires an exact fixed master.") }
        return try viaShapes(master: name, x: via.x, y: via.y).allSatisfy { shape in
            shape.points.allSatisfy { bounds.containsPoint(x: Int64($0.x), y: Int64($0.y)) }
        }
    }

    static func validateCutSpacing(_ shapes: [IRBoundary], minimum: Int32?) throws {
        // ponytail: pairwise primitive checks retain cut identity; use a spatial index when measured via counts exceed the admission budget.
        for i in shapes.indices {
            let first = Region(layer: shapes[i].layer, polygons: [shapes[i]])
            for j in shapes.indices where j > i {
                let second = Region(layer: shapes[j].layer, polygons: [shapes[j]])
                guard try first.intersection(second).isEmpty else {
                    throw PhysicalDesignTechnologyError.invalid("Distinct fixed via cuts overlap.")
                }
                if let minimum, minimum > 0 {
                    guard try PhysicalDesignFixedCutSeparation.separated(shapes[i], from: shapes[j], minimum: minimum) else {
                        throw PhysicalDesignTechnologyError.invalid("Fixed via cuts violate declared edge-to-edge SPACING.")
                    }
                }
            }
        }
    }

    private static func validateQualifiedEnclosureStack(cutLayer: Int16, lowerLayer: Int16, upperLayer: Int16,
        inputs: PhysicalDesignProcessInputs, layerMaps: [String: [String: Int16]]) throws {
        var declarations = 0
        for assetID in inputs.technologyViews.keys.sorted() {
            guard let document = inputs.technologyViews[assetID], let mapping = layerMaps[assetID] else {
                throw PhysicalDesignTechnologyError.invalid("Qualified ENCLOSURE source order disappeared.")
            }
            for (index, layer) in document.layers.enumerated() where mapping[layer.name] == cutLayer {
                declarations += 1
                guard layer.type == .cut,
                      let below = document.layers[..<index].last(where: { $0.type == .routing }),
                      let above = document.layers[(index + 1)...].first(where: { $0.type == .routing }) else {
                    throw PhysicalDesignTechnologyError.unsupported("Qualified ENCLOSURE requires both adjacent routing layers in its exact technology source order.")
                }
                guard mapping[below.name] == lowerLayer, mapping[above.name] == upperLayer else {
                    throw PhysicalDesignTechnologyError.invalid("Fixed VIA triplet contradicts qualified ENCLOSURE technology source order.")
                }
            }
        }
        guard declarations == 1 else {
            throw PhysicalDesignTechnologyError.invalid("Qualified ENCLOSURE requires one unambiguous CUT declaration in technology source order.")
        }
    }

    private static func validateContact(_ shape: IRBoundary, metal: Region, enclosures: [(Int64, Int64)]) throws {
        let cut = Region(layer: shape.layer, polygons: [shape])
        guard try cut.subtracting(metal).isEmpty else {
            throw PhysicalDesignTechnologyError.invalid("Fixed via metal does not cover its cut geometry.")
        }
        guard !enclosures.isEmpty else { return }
        var unsupportedDirectionalCut = false
        for pair in enclosures {
            if let satisfied = try enclosureMatches(shape, cut: cut, metal: metal, pair: pair) {
                if satisfied { return }
            } else { unsupportedDirectionalCut = true }
        }
        if unsupportedDirectionalCut {
            throw PhysicalDesignTechnologyError.unsupported("Asymmetric ENCLOSURE requires a rectangular fixed cut when no supported alternative proves enclosure.")
        }
        throw PhysicalDesignTechnologyError.invalid("Fixed via metal violates all applicable ENCLOSURE alternatives.")
    }

    private static func enclosureMatches(_ shape: IRBoundary, cut: Region, metal: Region,
        pair: (Int64, Int64)) throws -> Bool? {
        let (first, second) = pair
        if first == second {
            let minimum = try coordinate(first, field: "cut enclosure")
            return try metal.enclosureViolations(inner: cut, minEnclosure: minimum).isEmpty
        }
        guard let bounds = cut.boundingBox else { throw PhysicalDesignTechnologyError.invalid("Fixed via cut is empty.") }
        func rectangle(_ dx: Int64, _ dy: Int64) throws -> Region {
            let x1 = try coordinate(Int64(bounds.minX) - dx, field: "cut enclosure x1")
            let x2 = try coordinate(Int64(bounds.maxX) + dx, field: "cut enclosure x2")
            let y1 = try coordinate(Int64(bounds.minY) - dy, field: "cut enclosure y1")
            let y2 = try coordinate(Int64(bounds.maxY) + dy, field: "cut enclosure y2")
            return Region(layer: shape.layer, polygons: [.init(layer: shape.layer, datatype: 0, points: [
                .init(x: x1, y: y1), .init(x: x2, y: y1), .init(x: x2, y: y2), .init(x: x1, y: y2), .init(x: x1, y: y1)])])
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Native fixed-contact API/CLI admits asymmetric offsets only for rectangular cuts. A nonrectangular directional alternative cannot prove success until exact polygon offsets are implemented and verified.
        guard try rectangle(0, 0).subtracting(cut).isEmpty else { return nil }
        return try rectangle(first, second).subtracting(metal).isEmpty
            || rectangle(second, first).subtracting(metal).isEmpty
    }

    func projectMasterPoint(_ point: IRPoint, master: Master, orientation: DEFOrientation, x: Int64, y: Int64) throws -> IRPoint {
        try projectMasterCoordinates(Int64(point.x), Int64(point.y), master: master, orientation: orientation, x: x, y: y)
    }

    private func projectMasterCoordinates(_ pointX: Int64, _ pointY: Int64, master: Master,
        orientation: DEFOrientation, x: Int64, y: Int64) throws -> IRPoint {
        let rotation = DEFIRConverter.orientationToTransform(orientation)
        func rotate(_ x: Int64, _ y: Int64) throws -> (Int64, Int64) {
            let reflectedY = rotation.mirrorX ? -y : y
            switch rotation.angle {
            case 90: return (-reflectedY, x)
            case 180: return (-x, -reflectedY)
            case 270: return (reflectedY, -x)
            case 0: return (x, reflectedY)
            default: throw PhysicalDesignTechnologyError.invalid("The standard orientation transform must be orthogonal and exact.")
            }
        }
        let corners = try [rotate(0, 0), rotate(master.width, 0), rotate(0, master.height), rotate(master.width, master.height)]
        let minX = min(corners[0].0, corners[1].0, corners[2].0, corners[3].0)
        let minY = min(corners[0].1, corners[1].1, corners[2].1, corners[3].1)
        let local = try rotate(pointX, pointY)
        return try Self.translated(local.0 - minX, local.1 - minY, x: x, y: y)
    }

    private func transform(_ shapes: [IRBoundary], master: Master, orientation: DEFOrientation, x: Int64, y: Int64) throws -> [IRBoundary] {
        return try shapes.map { shape in
            var projected = shape
            // Instance geometry needs its own coordinates; source point buffers remain immutable.
            projected.points = try shape.points.map { point in
                return try projectMasterCoordinates(Int64(point.x) + Int64(master.origin.x), Int64(point.y) + Int64(master.origin.y),
                    master: master, orientation: orientation, x: x, y: y)
            }
            return projected
        }
    }

    private static func portShapes(_ ports: [LEFPort], layerMap: [String: Int16], vias: [String: Via], units: Int, allowEmpty: Bool = false) throws -> [IRBoundary] {
        var result: [IRBoundary] = []
        for port in ports {
            let layer = try layer(port.layerName, in: layerMap)
            if !port.rects.isEmpty || !port.polygons.isEmpty {
                result += try shapes(rectangles: port.rects, polygons: port.polygons, layer: layer, units: units)
            }
            for reference in port.vias {
                guard let via = vias[reference.viaName], layer == via.lowerLayer || layer == via.upperLayer else {
                    throw PhysicalDesignTechnologyError.invalid("PORT VIA \(reference.viaName) has no matching fixed stack on its declared layer.")
                }
                let origin = try point(reference.point, units: units)
                result += try via.shapes.map { shape in
                    var placed = shape
                    placed.points = try shape.points.map { try translated(Int64($0.x), Int64($0.y), x: Int64(origin.x), y: Int64(origin.y)) }
                    return placed
                }
            }
        }
        guard allowEmpty || !result.isEmpty else { throw PhysicalDesignTechnologyError.invalid("A physical pin requires retained port geometry.") }
        return result
    }

    private static func shapes(rectangles: [LEFRect], polygons: [[LEFPoint]], layer: Int16, units: Int) throws -> [IRBoundary] {
        var result: [IRBoundary] = []
        for rectangle in rectangles {
            // FIXME(INCOMPLETE_IMPLEMENTATION): Native shape projection has no mask-aware rule engine. API/CLI MASK-qualified shapes must fail until mask identity and same/different-mask process rules are implemented and verified.
            guard rectangle.mask == nil else { throw PhysicalDesignTechnologyError.unsupported("Native MASK-qualified geometry requires mask-aware process rules.") }
            let low = try point(.init(x: rectangle.x1, y: rectangle.y1), units: units)
            let high = try point(.init(x: rectangle.x2, y: rectangle.y2), units: units)
            guard low.x < high.x, low.y < high.y else { throw PhysicalDesignTechnologyError.invalid("A physical RECT requires positive exact extents.") }
            result.append(.init(layer: layer, datatype: 0, points: [low, .init(x: high.x, y: low.y), high, .init(x: low.x, y: high.y), low]))
        }
        for polygon in polygons {
            var points = try polygon.map { try point($0, units: units) }
            PolygonGeometry.ensureClosed(&points)
            guard points.count >= 5, PolygonGeometry.isManhattan(points) else { throw PhysicalDesignTechnologyError.unsupported("Native process polygons require nondegenerate rectilinear geometry.") }
            try validateSimple(points)
            result.append(.init(layer: layer, datatype: 0, points: points))
        }
        guard !result.isEmpty else { throw PhysicalDesignTechnologyError.invalid("A physical layer requires explicit shape geometry.") }
        return result
    }

    private static func validateSimple(_ points: [IRPoint]) throws {
        let count = points.count - 1
        for i in 0..<count {
            guard points[i] != points[i + 1] else { throw PhysicalDesignTechnologyError.invalid("A physical polygon has a zero-length edge.") }
            // ponytail: quadratic validation in polygon vertices; replace with a sweep when measured profile sizes require it.
            for j in (i + 1)..<count where j != i + 1 && !(i == 0 && j == count - 1) {
                let a = points[i], b = points[i + 1], c = points[j], d = points[j + 1]
                let overlapX = max(min(a.x, b.x), min(c.x, d.x)) <= min(max(a.x, b.x), max(c.x, d.x))
                let overlapY = max(min(a.y, b.y), min(c.y, d.y)) <= min(max(a.y, b.y), max(c.y, d.y))
                guard !overlapX || !overlapY else { throw PhysicalDesignTechnologyError.invalid("A physical polygon intersects or touches a nonadjacent edge.") }
            }
        }
    }

    private static func layer(_ name: String, in mapping: [String: Int16]) throws -> Int16 {
        guard let layer = mapping[name] else { throw PhysicalDesignTechnologyError.invalid("Physical layer \(name) is not explicitly mapped by its source asset.") }
        return layer
    }
    private static func point(_ point: LEFPoint, units: Int) throws -> IRPoint {
        .init(x: try coordinate(PhysicalDesignProcessInputs.dbu(point.x, units: units, field: "physical x", signed: true), field: "physical x"),
              y: try coordinate(PhysicalDesignProcessInputs.dbu(point.y, units: units, field: "physical y", signed: true), field: "physical y"))
    }
    private static func dimension(_ value: Double?, units: Int, field: String) throws -> Int64 {
        let result = try PhysicalDesignProcessInputs.dbu(value, units: units, field: field, positive: true)
        _ = try coordinate(result, field: field)
        return result
    }
    private static func coordinate(_ value: Int64, field: String) throws -> Int32 {
        guard let result = Int32(exactly: value) else { throw PhysicalDesignTechnologyError.invalid("\(field) is outside the native shape backend coordinate range.") }
        return result
    }
    private static func translated(_ localX: Int64, _ localY: Int64, x: Int64, y: Int64) throws -> IRPoint {
        let (newX, overflowX) = localX.addingReportingOverflow(x)
        let (newY, overflowY) = localY.addingReportingOverflow(y)
        guard !overflowX, !overflowY else { throw PhysicalDesignTechnologyError.invalid("Physical instance geometry translation overflows.") }
        return try .init(x: coordinate(newX, field: "instance x"), y: coordinate(newY, field: "instance y"))
    }
}
