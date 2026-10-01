import Foundation
import CircuiteFoundation
import PDKCore
import LEF

// FIXME(INCOMPLETE_IMPLEMENTATION): Native API/CLI technology preparation consumes scalar LEF routing constraints only. Cell pin access, legal via stacks and advanced process rules must be implemented and independently verified before this path can support production correctness.
enum PhysicalDesignTechnologyConstraints {
    static func prepare(
        _ snapshot: PhysicalDesignSnapshot,
        request: PhysicalDesignRequest,
        store: any PhysicalDesignArtifactStore
    ) async throws -> PhysicalDesignSnapshot {
        let bindings = request.inputBindings.filter { $0.descriptor.kind == .technology && $0.descriptor.format == .lef }
        guard !bindings.isEmpty else {
            guard snapshot.metadata["technologyLEFContentIDs"] == nil else {
                throw PhysicalDesignTechnologyError.invalid("A technology-prepared snapshot requires retained technology LEF inputs for every subsequent stage.")
            }
            return snapshot
        }
        guard bindings.allSatisfy({ $0.descriptor.role == .input && $0.reference.digest.algorithm == .sha256 }),
              request.pdk.manifest.digest.algorithm == .sha256,
              Set(bindings.map(\.reference)).isSubset(of: Set(request.inputs)),
              snapshot.validationDiagnostics().isEmpty,
              request.configuration.validationDiagnostics().isEmpty else {
            throw PhysicalDesignTechnologyError.invalid("Technology preparation requires valid configuration, snapshot and input-role LEF bindings.")
        }
        let manifestData = try await store.read(request.requireBinding(for: request.pdk.manifest))
        let manifest: PDKManifest
        do { manifest = try PDKManifestCodec.decode(data: manifestData) }
        catch { throw PhysicalDesignTechnologyError.invalid("PDK manifest decoding failed: \(error.localizedDescription)") }
        guard manifest.processID == request.pdk.processID, manifest.version == request.pdk.version,
              request.pdk.digest.lowercased() == request.pdk.manifest.digest.hexadecimalValue else {
            throw PhysicalDesignTechnologyError.invalid("Retained PDK manifest identity does not match the selected process, version or digest.")
        }
        var views: [(document: LEFDocument, layerIDs: Set<String>)] = []
        for binding in bindings {
            try Task.checkCancellation()
            let assets = manifest.assets.filter {
                $0.role == .technology && $0.format == .lef
                    && $0.sha256?.lowercased() == binding.reference.digest.hexadecimalValue
                    && $0.byteCount.flatMap(UInt64.init(exactly:)) == binding.reference.byteCount
            }
            guard assets.count == 1, let asset = assets.first else {
                throw PhysicalDesignTechnologyError.invalid("Technology LEF \(binding.path) must match exactly one manifest technology asset by digest and byte count.")
            }
            let data = try await store.read(binding)
            let document: LEFDocument
            do {
                document = try LEFLibraryReader.read(data)
                // The public reader drops second-axis values and qualified spacing. Token preflight prevents that loss without replacing the standard parser.
                guard let text = String(data: data, encoding: .utf8) else { throw LEFError.invalidEncoding }
                let tokens = try LEFTokenizer.tokenize(text)
                for index in tokens.indices where ["PITCH", "OFFSET", "SPACING"].contains(tokens[index].uppercased()) {
                    if index + 1 < tokens.count, Double(tokens[index + 1]) != nil,
                       index + 2 >= tokens.count || tokens[index + 2] != ";" {
                        throw PhysicalDesignTechnologyError.unsupported("Technology \(tokens[index]) must have one unqualified scalar value.")
                    }
                }
                guard !document.layers.contains(where: { $0.spacingTable != nil }) else {
                    throw PhysicalDesignTechnologyError.unsupported("Technology SPACINGTABLE is not implemented by native routing.")
                }
            } catch let error as PhysicalDesignTechnologyError { throw error }
            catch { throw PhysicalDesignTechnologyError.invalid("Technology LEF parsing failed: \(error.localizedDescription)") }
            let layerIDs = Set(manifest.crossViewMappings.filter { $0.assetID == asset.assetID && $0.view == .lef }.flatMap(\.layerIDs))
            views.append((document, layerIDs))
        }
        let core = try coreRectangle(snapshot: snapshot, request: request)
        let constraints = request.configuration.implementationConstraints ?? .default
        var output = snapshot
        var state = output.implementationState ?? .init()
        let suppliedTracks = state.tracks
        var generatedTracks: [PhysicalDesignImplementationState.Track] = []
        var usedLayerIDs: Set<String> = []
        var usedLEFNames: Set<String> = []
        for number in request.configuration.preferredRoutingLayers {
            let definitions = manifest.layers.filter { $0.number == number && $0.isRoutingLayer }
            guard definitions.count == 1, let definition = definitions.first else {
                throw PhysicalDesignTechnologyError.invalid("Configured layer \(number) must identify one canonical routing layer.")
            }
            let names = Set([definition.name] + definition.aliases)
            let layers = views.filter { $0.layerIDs.contains(definition.layerID) }.flatMap { view in
                view.document.layers.filter { $0.type == .routing && names.contains($0.name) }
            }
            guard layers.count == 1, let layer = layers.first, let direction = layer.direction else {
                throw PhysicalDesignTechnologyError.invalid("Layer \(definition.layerID) requires one mapped LEF routing layer with direction.")
            }
            guard usedLayerIDs.insert(definition.layerID).inserted, usedLEFNames.insert(layer.name).inserted else {
                throw PhysicalDesignTechnologyError.invalid("Configured layers cannot reuse canonical layer IDs or a LEF routing layer.")
            }
            let pitch = try dbu(layer.pitch, units: snapshot.unitsPerMicron, field: "\(layer.name).PITCH", positive: true)
            let offset = try dbu(layer.offset, units: snapshot.unitsPerMicron, field: "\(layer.name).OFFSET")
            let defaultWidth = try dbu(layer.width, units: snapshot.unitsPerMicron, field: "\(layer.name).WIDTH", positive: true)
            let width = try layer.minwidth.map { try dbu($0, units: snapshot.unitsPerMicron, field: "\(layer.name).MINWIDTH", positive: true) } ?? defaultWidth
            let spacing = try dbu(layer.spacing, units: snapshot.unitsPerMicron, field: "\(layer.name).SPACING")
            guard constraints.routeWidth >= width, constraints.routeSpacing >= spacing else {
                throw PhysicalDesignTechnologyError.invalid("Configured width/spacing is below LEF constraints for \(layer.name).")
            }
            if let maximum = layer.maxwidth,
               constraints.routeWidth > (try dbu(maximum, units: snapshot.unitsPerMicron, field: "\(layer.name).MAXWIDTH", positive: true)) {
                throw PhysicalDesignTechnologyError.invalid("Configured width exceeds LEF MAXWIDTH for \(layer.name).")
            }
            let nativeDirection = direction.rawValue.lowercased()
            if !suppliedTracks.isEmpty {
                let tracks = suppliedTracks.filter { $0.layer == number }
                guard !tracks.isEmpty, tracks.allSatisfy({ track in
                    let (span, spanOverflow) = (track.count - 1).multipliedReportingOverflow(by: track.spacing)
                    let (_, endOverflow) = track.origin.addingReportingOverflow(span)
                    return track.direction.lowercased() == nativeDirection && track.spacing == pitch
                        && normalizedRemainder(track.origin, pitch) == offset % pitch && !spanOverflow && !endOverflow
                }) else {
                    throw PhysicalDesignTechnologyError.invalid("Explicit tracks contradict the mapped LEF grid for layer \(number).")
                }
                continue
            }
            let lower = direction == .horizontal ? core.y : core.x
            let extent = direction == .horizontal ? core.height : core.width
            let delta = normalizedRemainder(offset % pitch - normalizedRemainder(lower, pitch), pitch)
            let (origin, overflow) = lower.addingReportingOverflow(delta)
            guard !overflow, delta < extent else {
                throw PhysicalDesignTechnologyError.invalid("Layer \(number) has no representable track inside the core.")
            }
            generatedTracks.append(.init(id: "technology_track_M\(number)", layer: number, direction: nativeDirection,
                                         origin: origin, spacing: pitch, count: (extent - 1 - delta) / pitch + 1))
        }
        if suppliedTracks.isEmpty { state.tracks = generatedTracks }
        output.implementationState = state
        output.metadata["technologyLEFContentIDs"] = bindings.map { $0.reference.id.description }.sorted().joined(separator: ",")
        return output
    }

    private static func dbu(_ value: Double?, units: Int, field: String, positive: Bool = false) throws -> Int64 {
        guard let value, value.isFinite, value >= 0, units > 0, units < 9_007_199_254_740_992 else {
            throw PhysicalDesignTechnologyError.invalid("\(field) requires a finite nonnegative micron value.")
        }
        let scaled = value * Double(units)
        let rounded = scaled.rounded()
        guard scaled.isFinite, scaled < 9_007_199_254_740_992,
              abs(rounded - scaled) <= scaled.ulp, !positive || rounded > 0 else {
            throw PhysicalDesignTechnologyError.invalid("\(field) cannot be represented as an exact positive/nonnegative integer DBU value.")
        }
        return Int64(rounded)
    }

    private static func normalizedRemainder(_ value: Int64, _ divisor: Int64) -> Int64 {
        let remainder = value % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }

    private static func coreRectangle(snapshot: PhysicalDesignSnapshot, request: PhysicalDesignRequest) throws -> PhysicalDesignSnapshot.Rect {
        if let core = snapshot.core { return core }
        guard request.stage == .floorplan else { throw PhysicalDesignTechnologyError.invalid("Technology tracks require an existing core outside floorplan execution.") }
        let configuration = request.configuration
        let die = snapshot.die ?? .init(x: 0, y: 0, width: configuration.dieWidth, height: configuration.dieHeight)
        let (x, xOverflow) = die.x.addingReportingOverflow(configuration.coreMargin)
        let (y, yOverflow) = die.y.addingReportingOverflow(configuration.coreMargin)
        let width = die.width - configuration.coreMargin * 2
        let height = die.height - configuration.coreMargin * 2
        guard !xOverflow, !yOverflow, width > 0, height > 0 else {
            throw PhysicalDesignTechnologyError.invalid("Technology tracks require a positive, representable proposed core.")
        }
        return .init(x: x, y: y, width: width, height: height)
    }
}
