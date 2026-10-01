import Foundation
import CircuiteFoundation
import PDKCore
import LEF

// FIXME(INCOMPLETE_IMPLEMENTATION): Native API/CLI technology preparation consumes typed LEF routing-grid constraints only. Cell pin access, legal via stacks and advanced process rules must be implemented and independently verified before this path can support production correctness.
enum PhysicalDesignTechnologyConstraints {
    static func prepare(
        _ snapshot: PhysicalDesignSnapshot,
        request: PhysicalDesignRequest,
        processInputs: PhysicalDesignProcessInputs?
    ) throws -> PhysicalDesignSnapshot {
        guard let processInputs, !processInputs.technologyViews.isEmpty else {
            guard snapshot.metadata["technologyLEFContentIDs"] == nil else {
                throw PhysicalDesignTechnologyError.invalid("A technology-prepared snapshot requires retained technology LEF inputs for every subsequent stage.")
            }
            return snapshot
        }
        guard snapshot.validationDiagnostics().isEmpty,
              request.configuration.validationDiagnostics().isEmpty else {
            throw PhysicalDesignTechnologyError.invalid("Technology preparation requires valid configuration and snapshot geometry.")
        }
        let sourceIDs = processInputs.technologyViews.keys.compactMap {
            request.processAssets[$0]?.reference.id.description
        }.sorted().joined(separator: ",")
        if let retained = snapshot.metadata["technologyLEFContentIDs"], retained != sourceIDs {
            throw PhysicalDesignTechnologyError.invalid("A prepared snapshot cannot resume with changed technology source identities.")
        }
        let manifest = processInputs.manifest
        var views: [(document: LEFDocument, layerIDs: Set<String>)] = []
        for assetID in processInputs.technologyViews.keys.sorted() {
            guard let document = processInputs.technologyViews[assetID] else {
                throw PhysicalDesignTechnologyError.invalid("A selected technology view must remain available during preparation.")
            }
            guard !document.layers.contains(where: { $0.spacingTable != nil }) else {
                throw PhysicalDesignTechnologyError.unsupported("Technology SPACINGTABLE is not implemented by native routing.")
            }
            let layerIDs = Set(manifest.crossViewMappings.filter {
                $0.assetID == assetID && $0.view == .lef
            }.flatMap(\.layerIDs))
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
            let selectedPitch = direction == .horizontal ? layer.pitch?.y : layer.pitch?.x
            let selectedOffset = direction == .horizontal ? layer.offset?.y : layer.offset?.x
            let pitch = try PhysicalDesignProcessInputs.dbu(selectedPitch, units: snapshot.unitsPerMicron, field: "\(layer.name).PITCH", positive: true)
            let offset = try PhysicalDesignProcessInputs.dbu(selectedOffset, units: snapshot.unitsPerMicron, field: "\(layer.name).OFFSET")
            let defaultWidth = try PhysicalDesignProcessInputs.dbu(layer.width, units: snapshot.unitsPerMicron, field: "\(layer.name).WIDTH", positive: true)
            let width = try layer.minwidth.map { try PhysicalDesignProcessInputs.dbu($0, units: snapshot.unitsPerMicron, field: "\(layer.name).MINWIDTH", positive: true) } ?? defaultWidth
            let spacing = try PhysicalDesignProcessInputs.dbu(layer.spacing, units: snapshot.unitsPerMicron, field: "\(layer.name).SPACING")
            guard constraints.routeWidth >= width, constraints.routeSpacing >= spacing else {
                throw PhysicalDesignTechnologyError.invalid("Configured width/spacing is below LEF constraints for \(layer.name).")
            }
            if let maximum = layer.maxwidth,
               constraints.routeWidth > (try PhysicalDesignProcessInputs.dbu(maximum, units: snapshot.unitsPerMicron, field: "\(layer.name).MAXWIDTH", positive: true)) {
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
        output.metadata["technologyLEFContentIDs"] = sourceIDs
        return output
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
