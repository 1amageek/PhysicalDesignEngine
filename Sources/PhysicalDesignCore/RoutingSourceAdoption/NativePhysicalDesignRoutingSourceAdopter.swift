import Foundation
import CircuiteFoundation
import PDKCore

public struct NativePhysicalDesignRoutingSourceAdopter: PhysicalDesignRoutingSourceAdopting {
    public init() {}

    public func adopt(_ input: PhysicalDesignRoutingSourceAdoptionInput,
                      store: any PhysicalDesignArtifactStore) async throws -> PhysicalDesignRoutingSourceAdoptionResult {
        do { return try await checked(input, store: store) }
        catch let error as CancellationError { throw error }
        catch let error as PhysicalDesignRoutingSourceAdoptionError { throw error }
        catch let error as PhysicalDesignTechnologyError {
            if case .unsupported = error {
                throw PhysicalDesignRoutingSourceAdoptionError(.unsupported, "The extended source is unsupported.", cause: error)
            }
            throw PhysicalDesignRoutingSourceAdoptionError(.sourceValidation, "Source geometry validation failed.", cause: error)
        } catch {
            throw PhysicalDesignRoutingSourceAdoptionError(.sourceValidation, "Checked source intake failed.", cause: error)
        }
    }

    private func checked(_ input: PhysicalDesignRoutingSourceAdoptionInput,
                         store: any PhysicalDesignArtifactStore) async throws -> PhysicalDesignRoutingSourceAdoptionResult {
        try Task.checkCancellation()
        let old = input.oldRequest, new = input.newRequest, limits = input.limits
        guard input.parent.validationDiagnostics().isEmpty, input.parent.layoutArtifact.descriptor.format == .json,
              input.parent.layoutDigest == input.parent.layoutArtifact.reference.digest.hexadecimalValue,
              old.inputLayout == input.parent, new.inputLayout == input.parent,
              old.initialSnapshot == nil, new.initialSnapshot == nil,
              old.design == new.design, old.constraints == new.constraints,
              old.pdk.processID == new.pdk.processID, old.pdk.version == new.pdk.version else {
            throw PhysicalDesignRoutingSourceAdoptionError(.parentMismatch, "Adoption requires the exact parent and unchanged logical/process scope.")
        }
        guard new.stage == .detailedRouting || new.stage == .globalRouting,
              new.configuration.implementationConstraints?.sourceRoutingWidthPolicy == .sourceDefault,
              new.configuration.validationDiagnostics().isEmpty,
              new.clockTimingModel == nil, new.placementTimingProfile == nil, new.repairMeasurementProfile == nil else {
            throw PhysicalDesignRoutingSourceAdoptionError(.unsupported, "Source extension requires source-default ordinary routing without old timing/repair profiles.")
        }
        guard limits.maximumCombinedInputBytes > 0, limits.maximumSourceAssets > 0, limits.maximumSourceEntries > 0,
              old.processAssets.count <= limits.maximumSourceAssets,
              new.processAssets.count <= limits.maximumSourceAssets,
              Set(old.processAssets.keys) == Set(new.processAssets.keys) else {
            throw PhysicalDesignRoutingSourceAdoptionError(.limitsExceeded, "Source asset inventory exceeds the selected profile or caller allowance.")
        }
        var remainingBytes = UInt64(limits.maximumCombinedInputBytes)
        func admit(_ reference: ArtifactReference, remaining: inout UInt64) throws {
            try Task.checkCancellation()
            guard reference.digest.algorithm == .sha256, reference.byteCount > 0,
                  reference.byteCount <= remaining else {
                throw PhysicalDesignRoutingSourceAdoptionError(.limitsExceeded, "Combined parent and old/new source buffers exceed the caller allowance.")
            }
            remaining -= reference.byteCount
        }
        try admit(input.parent.layoutArtifact.reference, remaining: &remainingBytes)
        for request in [old, new] {
            try admit(request.pdk.manifest, remaining: &remainingBytes)
            for binding in request.processAssets.values { try admit(binding.reference, remaining: &remainingBytes) }
        }
        var readable: Set<PhysicalDesignArtifactBinding> = [input.parent.layoutArtifact]
        for request in [old, new] {
            readable.insert(try request.requireBinding(for: request.pdk.manifest))
            readable.formUnion(request.processAssets.values)
        }
        let sourceStore = PhysicalDesignRoutingSourceReadStore(underlying: store, allowed: readable,
            maximumBytes: UInt64(limits.maximumCombinedInputBytes))
        let codec = PhysicalDesignJSONCodec()
        let parentBytes = try await sourceStore.read(input.parent.layoutArtifact)
        let parent = try codec.decode(PhysicalDesignSnapshot.self, from: parentBytes)
        guard parent.topCell == input.parent.topCell, parent.topCell == old.design.topDesignName,
              parent.processManifest == old.pdk.manifest, parent.processAssets == old.processAssets.mapValues(\.reference) else {
            throw PhysicalDesignRoutingSourceAdoptionError(.parentMismatch, "Parent geometry does not bind the old exact source inventory.")
        }
        guard let oldInputs = try await PhysicalDesignProcessInputs.load(request: old, store: sourceStore),
              let newInputs = try await PhysicalDesignProcessInputs.load(request: new, store: sourceStore),
              Set(oldInputs.technologyViews.keys) == Set(newInputs.technologyViews.keys),
              Set(oldInputs.cellViews.keys) == Set(newInputs.cellViews.keys) else {
            throw PhysicalDesignRoutingSourceAdoptionError(.sourceMismatch, "Old and new source roles must identify the same explicit asset IDs.")
        }
        var remainingEntries = limits.maximumSourceEntries
        try PhysicalDesignRoutingSourceFacts.admitEntries(oldInputs, remaining: &remainingEntries)
        try PhysicalDesignRoutingSourceFacts.admitEntries(newInputs, remaining: &remainingEntries)
        for asset in oldInputs.cellViews.keys {
            guard old.processAssets[asset]?.reference == new.processAssets[asset]?.reference else {
                throw PhysicalDesignRoutingSourceAdoptionError(.sourceMismatch, "Cell PORT/OBS sources must remain byte-identical.")
            }
        }
        let newLayerIDs = Set(newInputs.manifest.layers.map(\.layerID))
        let newNumbers = newInputs.manifest.layers.map(\.number)
        guard newLayerIDs.count == newInputs.manifest.layers.count,
              Set(newNumbers).count == newNumbers.count, newNumbers.allSatisfy({ $0 > 0 }) else {
            throw PhysicalDesignRoutingSourceAdoptionError(.layerCollision, "New layer IDs and native numbers must be unique and positive.")
        }
        for layer in oldInputs.manifest.layers {
            try Task.checkCancellation()
            guard newInputs.manifest.layers.filter({ $0.layerID == layer.layerID }) == [layer] else {
                throw PhysicalDesignRoutingSourceAdoptionError(.layerCollision, "Every old layer ID, native number and role must remain identical.")
            }
        }
        var facts: [String] = []
        for asset in oldInputs.technologyViews.keys.sorted() {
            try Task.checkCancellation()
            guard let previous = oldInputs.technologyViews[asset], let extended = newInputs.technologyViews[asset],
                  try PhysicalDesignRoutingSourceFacts.preserved(previous, in: extended) else {
                throw PhysicalDesignRoutingSourceAdoptionError(.changedFacts, "An old typed technology fact changed in asset \(asset).")
            }
            facts.append("\(asset)/header")
            for layer in previous.layers { facts.append("\(asset)/layer/\(layer.name)") }
            for via in previous.vias { facts.append("\(asset)/via/\(via.name)") }
            for site in previous.sites { facts.append("\(asset)/site/\(site.name)") }
        }
        let oldGeometry = try PhysicalDesignProcessGeometry(inputs: oldInputs, request: old, units: parent.unitsPerMicron)
        try oldGeometry.validate(parent)
        _ = try PhysicalDesignTechnologyConstraints.prepare(parent, request: old, processInputs: oldInputs, processGeometry: oldGeometry)
        let newGeometry = try PhysicalDesignProcessGeometry(inputs: newInputs, request: new, units: parent.unitsPerMicron)
        var candidate = parent
        candidate.processManifest = new.pdk.manifest
        candidate.processAssets = new.processAssets.mapValues(\.reference)
        for index in candidate.clockTrees.indices { candidate.clockTrees[index].timingEstimate = nil }
        candidate.implementationState?.placementProof = nil
        candidate.implementationState?.routingEvidence = nil
        candidate.implementationState?.repairProofs.removeAll()
        candidate.metadata["clockTimingStatus"] = "invalidated_by_routing_source_adoption"
        candidate = try PhysicalDesignTechnologyConstraints.prepareRoutingSourceExtension(candidate,
            request: new, processInputs: newInputs, processGeometry: newGeometry)
        try newGeometry.validate(candidate)
        try newGeometry.validateCTSMetalAreas(candidate)
        for route in candidate.routes {
            let special = candidate.nets.first { $0.id == route.netID }?.routingClass == .special
            for segment in route.segments {
                guard let width = segment.widthDBU else {
                    throw PhysicalDesignRoutingSourceAdoptionError(.unsupported, "Retained route widths must remain qualified.")
                }
                _ = try newGeometry.routingWidthAndSpacing(layer: segment.layer, units: candidate.unitsPerMicron,
                    width: width, explicitSpecialWidth: special, areaHandledSeparately: true)
            }
        }
        let oldIDs = Set(oldInputs.manifest.layers.map(\.layerID))
        let oldTrackIDs = Set(parent.implementationState?.tracks.map(\.id) ?? [])
        let lineage = PhysicalDesignRoutingSourceAdoptionLineage(parent: input.parent,
            oldManifest: old.pdk.manifest, newManifest: new.pdk.manifest,
            oldAssets: old.processAssets.mapValues(\.reference), newAssets: new.processAssets.mapValues(\.reference),
            checkedFactIDs: facts, addedLayerIDs: newInputs.manifest.layers.map(\.layerID).filter { !oldIDs.contains($0) },
            addedTrackIDs: (candidate.implementationState?.tracks ?? []).map(\.id).filter { !oldTrackIDs.contains($0) })
        let lineageBytes = try codec.encode(lineage)
        guard lineageBytes.count <= limits.maximumCombinedInputBytes,
              let text = String(data: lineageBytes, encoding: .utf8) else {
            throw PhysicalDesignRoutingSourceAdoptionError(.limitsExceeded, "Source lineage exceeds its logical output allowance.")
        }
        candidate.metadata["routingSourceAdoptionLineage"] = text
        return .init(snapshot: candidate, lineage: lineage)
    }
}
