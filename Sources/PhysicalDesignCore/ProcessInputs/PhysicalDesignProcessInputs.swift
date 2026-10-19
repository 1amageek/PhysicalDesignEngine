import CircuiteFoundation
import LEF
import PDKCore

struct PhysicalDesignProcessInputs: Sendable {
    let manifest: PDKManifest
    let technologyViews: [String: LEFDocument]
    let cellViews: [String: LEFDocument]

    var hasSourceAntennaLaws: Bool {
        [technologyViews, cellViews].contains { views in
            views.values.contains { $0.layers.contains { !$0.antennaStatements.isEmpty } }
        }
    }

    var requiresSourceGeometry: Bool {
        hasSourceAntennaLaws || !cellViews.isEmpty || technologyViews.values.contains { view in
            view.layers.contains { !$0.minimumEnclosedAreas.isEmpty }
        }
    }

    func requiresSourceGeometry(for request: PhysicalDesignRequest) -> Bool {
        requiresSourceGeometry || request.configuration.implementationConstraints?.sourceRoutingWidthPolicy == .sourceDefault
    }

    static func load(
        request: PhysicalDesignRequest,
        store: any PhysicalDesignArtifactStore
    ) async throws -> Self? {
        let declared = Set(request.processAssets.values)
        let lefBindings = Set(request.inputBindings.filter { $0.descriptor.format == .lef })
        guard lefBindings == declared else {
            throw PhysicalDesignTechnologyError.invalid("Every physical LEF binding requires one explicit manifest asset ID in processAssets.")
        }
        guard !declared.isEmpty else { return nil }
        guard declared.allSatisfy({
            $0.descriptor.role == .input && $0.descriptor.format == .lef
                && $0.reference.digest.algorithm == .sha256
                && request.inputs.contains($0.reference)
        }), request.pdk.manifest.digest.algorithm == .sha256 else {
            throw PhysicalDesignTechnologyError.invalid("Process sources require input-role SHA-256 bindings and retained provenance.")
        }
        let manifestData = try await store.read(request.requireBinding(for: request.pdk.manifest))
        let manifest: PDKManifest
        do { manifest = try PDKManifestCodec.decode(data: manifestData) }
        catch { throw PhysicalDesignTechnologyError.invalid("PDK manifest decoding failed: \(error.localizedDescription)") }
        guard manifest.processID == request.pdk.processID, manifest.version == request.pdk.version,
              request.pdk.digest.lowercased() == request.pdk.manifest.digest.hexadecimalValue else {
            throw PhysicalDesignTechnologyError.invalid("Retained PDK manifest identity does not match the selected process, version or digest.")
        }
        var technologyViews: [String: LEFDocument] = [:]
        var cellViews: [String: LEFDocument] = [:]
        var parsed: [PhysicalDesignArtifactBinding: LEFDocument] = [:]
        for assetID in request.processAssets.keys.sorted() {
            try Task.checkCancellation()
            guard !assetID.isEmpty, let binding = request.processAssets[assetID] else {
                throw PhysicalDesignTechnologyError.invalid("A process source requires a nonempty manifest asset ID.")
            }
            let matchingAssets = manifest.assets.filter { $0.assetID == assetID }
            guard matchingAssets.count == 1, let asset = matchingAssets.first,
                  asset.format == .lef, asset.kind == binding.descriptor.kind,
                  asset.sha256?.lowercased() == binding.reference.digest.hexadecimalValue,
                  asset.byteCount.flatMap(UInt64.init(exactly:)) == binding.reference.byteCount else {
                throw PhysicalDesignTechnologyError.invalid("Process asset \(assetID) must identify one exact manifest LEF source by kind, digest and byte count.")
            }
            guard asset.role == .technology || asset.role == .cell else {
                throw PhysicalDesignTechnologyError.unsupported("Process asset \(assetID) must declare its technology or cell role explicitly.")
            }
            let document: LEFDocument
            if let retained = parsed[binding] { document = retained }
            else {
                let data = try await store.read(binding)
                do { document = try LEFLibraryReader.read(data) }
                catch { throw PhysicalDesignTechnologyError.invalid("Process asset \(assetID) LEF parsing failed: \(error.localizedDescription)") }
                parsed[binding] = document
            }
            if asset.role == .technology { technologyViews[assetID] = document }
            else { cellViews[assetID] = document }
        }
        let result = Self(manifest: manifest, technologyViews: technologyViews, cellViews: cellViews)
        _ = try result.obstructionSpacingUsesMinimumWidth()
        try result.validatePropertyCapabilities()
        try result.validateAntennaCapabilities()
        try result.validateEnclosureCapabilities(request: request)
        return result
    }

    func validateEnclosureCapabilities(request: PhysicalDesignRequest) throws {
        let views = technologyViews.merging(cellViews) { first, _ in first }
        func mappedLayers(assetID: String, name: String) -> [PDKLayerDefinition] {
            let ids = Set(manifest.crossViewMappings.filter { $0.assetID == assetID && $0.view == .lef }.flatMap(\.layerIDs))
            return manifest.layers.filter { ids.contains($0.layerID) && ($0.name == name || $0.aliases.contains(name)) }
        }
        for assetID in views.keys.sorted() {
            try Task.checkCancellation()
            guard let document = views[assetID] else {
                throw PhysicalDesignTechnologyError.invalid("An admitted enclosure source disappeared.")
            }
            for layer in document.layers where !layer.enclosures.isEmpty {
                let mapped = mappedLayers(assetID: assetID, name: layer.name)
                guard layer.type == .cut, mapped.count == 1, let cut = mapped.first,
                      !cut.isRoutingLayer, cut.purpose == .via || cut.purpose == .contact else {
                    throw PhysicalDesignTechnologyError.unsupported("Layer ENCLOSURE requires one exact mapped CUT source: \(layer.name).")
                }
                for rule in layer.enclosures {
                    guard rule.overhang1.isFinite, rule.overhang2.isFinite else {
                        throw PhysicalDesignTechnologyError.invalid("Layer ENCLOSURE overhangs must be finite.")
                    }
                    // FIXME(INCOMPLETE_IMPLEMENTATION): Native API/CLI enclosure admission implements nonnegative exact overhangs only. Signed negative geometry laws must remain unsupported until their actual coverage semantics are implemented and verified.
                    guard rule.overhang1 >= 0, rule.overhang2 >= 0 else {
                        throw PhysicalDesignTechnologyError.unsupported("Negative layer ENCLOSURE overhangs require implemented signed geometry semantics.")
                    }
                }
                guard layer.enclosures.contains(where: { $0.side != nil }) else { continue }
                guard technologyViews[assetID] != nil else {
                    throw PhysicalDesignTechnologyError.unsupported("Qualified ENCLOSURE requires technology-role source order.")
                }
                if !requiresSourceGeometry(for: request) {
                    let hasFixedCut = views.contains { id, view in
                        view.vias.contains { via in
                            via.layers.contains { mappedLayers(assetID: id, name: $0.layerName).contains { $0.layerID == cut.layerID } }
                        }
                    }
                    // FIXME(INCOMPLETE_IMPLEMENTATION): The technology-only API/CLI path without cell views, hole laws or source-default width does not construct fixed VIA geometry. Selected qualified fixed contacts must be refused until their exact source geometry is admitted on that path.
                    guard !hasFixedCut else {
                        throw PhysicalDesignTechnologyError.unsupported("Technology-only qualified ENCLOSURE fixed VIAs require source geometry admission.")
                    }
                }
            }
        }
    }

    func validateAntennaCapabilities() throws {
        try PhysicalDesignAntennaSourceProjection.validateSupported(inputs: self)
    }

    func validatePropertyCapabilities() throws {
        try Task.checkCancellation()
        for views in [technologyViews, cellViews] {
            for id in views.keys.sorted() {
                guard let document = views[id] else { throw PhysicalDesignTechnologyError.invalid("An admitted property source disappeared.") }
                // FIXME(INCOMPLETE_IMPLEMENTATION): Native API/CLI has no interpreter for LIBRARY property definition values. A value must remain unsupported until its actual process effect is implemented and verified.
                guard !document.propertyDefinitions.contains(where: { $0.libraryValue != nil }) else {
                    throw PhysicalDesignTechnologyError.unsupported("Native LIBRARY property definition values require implemented process semantics.")
                }
                for layer in document.layers {
                    try Task.checkCancellation()
                    let recognizedWell = layer.type == .masterslice && (layer.subtype == .nwell || layer.subtype == .pwell)
                    // FIXME(INCOMPLETE_IMPLEMENTATION): Native API/CLI retains all codec subtypes but admits well classification only. Other subtype families require their own process and geometry semantics before successful mutation.
                    guard layer.subtype == nil || recognizedWell else {
                        throw PhysicalDesignTechnologyError.unsupported("Native LEF58_TYPE subtype on layer \(layer.name) requires implemented process semantics.")
                    }
                    if recognizedWell {
                        let mappedIDs = Set(manifest.crossViewMappings.filter { $0.assetID == id && $0.view == .lef }.flatMap(\.layerIDs))
                        let mapped = manifest.layers.filter { mappedIDs.contains($0.layerID) && ($0.name == layer.name || $0.aliases.contains(layer.name)) }
                        guard mapped.count <= 1, mapped.allSatisfy({ $0.purpose == .well && !$0.isRoutingLayer }) else {
                            throw PhysicalDesignTechnologyError.invalid("LEF58_TYPE well classification contradicts mapped layer \(layer.name).")
                        }
                    }
                    for property in layer.properties {
                        // FIXME(INCOMPLETE_IMPLEMENTATION): Native API/CLI has no general layer-property rule interpreter. Unknown assignments must fail until their process effects are applied and tested.
                        guard property.name == "LEF58_TYPE", property.value.type == .string, recognizedWell else {
                            throw PhysicalDesignTechnologyError.unsupported("Native layer PROPERTY \(property.name) on \(layer.name) requires implemented process semantics.")
                        }
                    }
                }
            }
        }
    }

    func obstructionSpacingUsesMinimumWidth() throws -> Bool {
        var declarations: Set<Bool> = []
        for views in [technologyViews, cellViews] {
            for id in views.keys.sorted() {
                if let declared = views[id]?.obstructionSpacingUsesMinimumWidth { declarations.insert(declared) }
            }
        }
        guard declarations.count <= 1 else {
            throw PhysicalDesignTechnologyError.invalid("Conflicting USEMINSPACING OBS declarations cannot be mixed.")
        }
        return declarations.first ?? true
    }

    func databaseUnitsPerMicron(for outputUnits: Int) throws -> Int {
        var explicit: Set<Int> = []
        for id in technologyViews.keys.sorted() {
            guard let document = technologyViews[id] else { throw PhysicalDesignTechnologyError.invalid("DATABASE source view disappeared.") }
            if document.hasDatabaseUnitsDeclaration {
                guard let precision = Int(exactly: document.dbuPerMicron), precision > 0 else {
                    throw PhysicalDesignTechnologyError.invalid("DATABASE requires an exact positive source precision.")
                }
                explicit.insert(precision)
            }
        }
        guard explicit.count <= 1 else { throw PhysicalDesignTechnologyError.invalid("Selected technology DATABASE declarations disagree.") }
        let sourceUnits = explicit.first ?? 100
        for id in cellViews.keys.sorted() {
            guard let document = cellViews[id] else { throw PhysicalDesignTechnologyError.invalid("DATABASE cell view disappeared.") }
            guard !document.hasDatabaseUnitsDeclaration || document.dbuPerMicron == Double(sourceUnits) else {
                throw PhysicalDesignTechnologyError.invalid("Incremental cell DATABASE precision contradicts its exact technology context.")
            }
        }
        guard outputUnits > 0, outputUnits <= sourceUnits, sourceUnits.isMultiple(of: outputUnits) else {
            throw PhysicalDesignTechnologyError.invalid("Output DATABASE precision must divide source precision exactly and cannot be finer.")
        }
        return sourceUnits
    }

    static func dbu(_ value: Double?, units: Int, field: String, positive: Bool = false, signed: Bool = false) throws -> Int64 {
        guard let value, value.isFinite, signed || value >= 0, units > 0, units < 9_007_199_254_740_992 else {
            throw PhysicalDesignTechnologyError.invalid("\(field) requires a finite micron value within the allowed sign domain.")
        }
        let scaled = value * Double(units)
        let rounded = scaled.rounded()
        guard scaled.isFinite, abs(scaled) < 9_007_199_254_740_992,
              abs(rounded - scaled) <= scaled.ulp, !positive || rounded > 0 else {
            throw PhysicalDesignTechnologyError.invalid("\(field) cannot be represented as an exact integer DBU value in the required sign domain.")
        }
        return Int64(rounded)
    }
}
