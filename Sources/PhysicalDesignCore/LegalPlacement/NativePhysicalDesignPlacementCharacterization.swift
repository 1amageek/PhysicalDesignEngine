import CircuiteFoundation
import Foundation
import LEF
import STAEngine
import TimingCore

struct NativePhysicalDesignPlacementCharacterization: Sendable {
    struct RetainedParser: LibertySourceParsing {
        let source: OwnedLibertySource
        func parseSource(_ bytes: borrowing Span<UInt8>, limits: LibertySourceParseLimits,
                         resources: any LibertySourceResourceAccounting) throws(LibertySourceError) -> OwnedLibertySource {
            do {
                try resources.chargeWork(UInt64(bytes.count))
                let matches = source.withBytes { original in
                    guard bytes.count == original.count else { return false }
                    for index in 0..<bytes.count where bytes[index] != original[index] { return false }
                    return true
                }
                guard matches else { throw LibertySourceError.unsupportedSemantics("Retained placement Liberty bytes differ") }
                return source
            } catch let error as LibertySourceError { throw error }
            catch { throw .resource(error) }
        }
    }
    let profile: PhysicalDesignPlacementTimingProfile
    let budget: NativePhysicalDesignPlacementTimingBudget
    let graph: TimingDesign
    let constraints: TimingConstraintSet
    let parser: RetainedParser
    let strict: CharacterizedTimingLibrary?
    let sourceBindings: PhysicalDesignPlacementSourceBindings?
    let rcProjection: NativePhysicalDesignPlacementRCProjection?
    let inputData: [ArtifactID: Data]
    let inputReservations: [LibertySourceStorageReservation]
    let areaPicofaradsPerSquareMicron: Double
    let edgePicofaradsPerMicron: Double

    static func load(request: PhysicalDesignRequest, snapshot: PhysicalDesignSnapshot,
                     inputs: PhysicalDesignProcessInputs, geometry: PhysicalDesignProcessGeometry,
                     store: any PhysicalDesignArtifactStore, budget: NativePhysicalDesignPlacementTimingBudget) async throws -> Self {
        guard snapshot.routes.isEmpty, snapshot.vias.isEmpty, snapshot.powerStructures.isEmpty, snapshot.fills.isEmpty else {
            throw PhysicalDesignPlacementTimingError.invalidProfile("Pre-route timing cost requires a metal-free candidate; routed manufacturing closure is unavailable")
        }
        var data: [ArtifactID: Data] = [:]
        var reservations: [LibertySourceStorageReservation] = []
        func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
            try budget.check()
            guard request.inputBindings.contains(binding), request.inputs.contains(binding.reference), binding.descriptor.role == .input else {
                throw PhysicalDesignPlacementTimingError.invalidProfile("A placement characterization source is not an exact retained input")
            }
            if let bytes = data[binding.reference.id] { return bytes }
            try budget.chargeInput(binding.reference.byteCount)
            try budget.chargeWork(binding.reference.byteCount)
            reservations.append(try budget.reserveStorage(kind: .liveOwnedBytes, byteCount: binding.reference.byteCount))
            let bytes = try await store.read(binding)
            data[binding.reference.id] = bytes
            return bytes
        }
        let profile = try PhysicalDesignJSONCodec().decode(PhysicalDesignPlacementTimingProfile.self, from: await read(budget.reference.artifact))
        let legacy = profile.schemaVersion == 1 && profile.model == "lefGroundCapacitanceStarV1"
            && profile.clockPolicy == nil && profile.checkPolicy == nil
            && profile.operatingSupplyAssumptions == nil && profile.distributedRC == nil
        guard legacy || profile.isSourceBoundSequential,
              profile.manifest == request.pdk.manifest, geometry.manifestReference == profile.manifest,
              !profile.cornerID.isEmpty, !profile.conditionName.isEmpty,
              profile.minimumSetupSlackSeconds == nil || profile.minimumSetupSlackSeconds!.isFinite,
              let corner = inputs.manifest.corners.first(where: { $0.cornerID == profile.cornerID }),
              corner.rcCorner == profile.rcCornerID,
              corner.assetIDs.contains(profile.libertyAssetID), corner.assetIDs.contains(profile.capacitanceAssetID),
              let libraryAsset = inputs.manifest.assets.first(where: { $0.assetID == profile.libertyAssetID }),
              libraryAsset.role == .liberty, libraryAsset.sha256?.lowercased() == profile.library.reference.digest.hexadecimalValue,
              libraryAsset.byteCount.flatMap(UInt64.init(exactly:)) == profile.library.reference.byteCount,
              profile.library.descriptor.format == .liberty,
              let document = inputs.technologyViews[profile.capacitanceAssetID],
              let layerIndex = Int16(exactly: profile.wireLayer), let layer = geometry.sourceLayers[layerIndex],
              document.layers.contains(layer), layer.type == .routing,
              let capacitancePrecision = document.unitDeclarations.capacitancePicofarads,
              capacitancePrecision.isFinite, capacitancePrecision > 0,
              let area = layer.capacitance, let edge = layer.edgeCapacitance,
              area.isFinite, edge.isFinite, area >= 0, edge >= 0, area + edge > 0,
              profile.wireWidthDBU > 0, let minimumWidth = layer.minwidth ?? layer.width,
              Double(profile.wireWidthDBU) / Double(snapshot.unitsPerMicron) >= minimumWidth,
              layer.maxwidth == nil || Double(profile.wireWidthDBU) / Double(snapshot.unitsPerMicron) <= layer.maxwidth! else {
            throw PhysicalDesignPlacementTimingError.invalidProfile("Exact PDK/corner/Liberty/LEF capacitance units, material or width are unavailable")
        }
        let libraryData = try await read(profile.library)
        let manifestBinding = try request.requireBinding(for: request.pdk.manifest)
        _ = try await read(manifestBinding)
        let constraints = try SDCParser().parse(await read(request.constraints))
        let graph = try TimingDesignParser().parse(await read(request.requireBinding(for: request.design.artifact)), topDesignName: request.design.topDesignName)
        let source: OwnedLibertySource
        do { source = try libraryData.withUnsafeBytes { raw in
            try LibertyParser().parseSource(raw.bindMemory(to: UInt8.self).span,
                limits: .init(maximumNestingDepth: 64), resources: budget)
        } }
        catch let error as LibertySourceError {
            if case .resource(let cause) = error {
                if cause is CancellationError { throw CancellationError() }
                if let failure = cause as? PhysicalDesignPlacementTimingError { throw failure }
            }
            throw PhysicalDesignPlacementTimingError.source(error)
        }
        let selectedGraph: TimingDesign
        let bindings: PhysicalDesignPlacementSourceBindings?
        let projection: NativePhysicalDesignPlacementRCProjection?
        let strict: CharacterizedTimingLibrary?
        if profile.isSourceBoundSequential {
            guard snapshot.clockTrees.isEmpty else {
                throw PhysicalDesignPlacementTimingError.invalidProfile("Pre-route placement cannot consume a retained physical CTS proof")
            }
            let classification = try NativePhysicalDesignPlacementTerminalClassification(graph: graph, source: source,
                snapshot: snapshot, inputs: inputs, geometry: geometry, budget: budget)
            selectedGraph = classification.signalGraph
            bindings = .init(terminals: classification.terminals, constants: classification.constants,
                sequentialBindings: classification.sequentialBindings)
            projection = try .init(profile: profile, inputs: inputs, geometry: geometry)
            strict = nil
        } else {
            selectedGraph = graph; bindings = nil; projection = nil
            let names = Set(snapshot.cells.map(\.master)).sorted()
            for name in names {
                guard let cell = source.library.cells[name], cell.sequentialModel == nil,
                      let original = source.cells.first(where: { $0.name == name }), original.sequential.isEmpty else {
                    throw PhysicalDesignPlacementTimingError.invalidProfile("Legacy pre-route placement requires characterized combinational cells")
                }
            }
            do { strict = try libraryData.withUnsafeBytes { raw in
                try LibertyParser().parseCharacterizedSource(raw.bindMemory(to: UInt8.self).span,
                    cellNames: names, propagationCellNames: names, sequentialPropagationCellNames: [], limits: .init(maximumNestingDepth: 64), resources: budget)
            } }
            catch let error as LibertySourceError {
                if case .resource(let cause) = error {
                    if cause is CancellationError { throw CancellationError() }
                    if let failure = cause as? PhysicalDesignPlacementTimingError { throw failure }
                }
                throw PhysicalDesignPlacementTimingError.source(error)
            }
        }
        try budget.check()
        return .init(profile: profile, budget: budget, graph: selectedGraph, constraints: constraints, parser: .init(source: source),
            strict: strict, sourceBindings: bindings, rcProjection: projection, inputData: data, inputReservations: reservations,
            areaPicofaradsPerSquareMicron: area, edgePicofaradsPerMicron: edge)
    }
}
