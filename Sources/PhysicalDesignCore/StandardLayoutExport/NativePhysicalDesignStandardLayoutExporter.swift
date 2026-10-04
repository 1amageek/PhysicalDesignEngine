import Foundation

public struct NativePhysicalDesignStandardLayoutExporter: PhysicalDesignStandardLayoutExporting {
    public init() {}

    public func exportDEF(
        snapshot: PhysicalDesignSnapshot,
        request: PhysicalDesignRequest,
        artifactStore: any PhysicalDesignArtifactStore,
        limits: PhysicalDesignStandardLayoutExportLimits
    ) async throws -> Data {
        do {
            try Task.checkCancellation()
            guard request.schemaVersion == PhysicalDesignRequest.currentSchemaVersion,
                  snapshot.processManifest == request.pdk.manifest,
                  !request.processAssets.isEmpty,
                  snapshot.processAssets == request.processAssets.mapValues(\.reference),
                  request.inputs.contains(request.pdk.manifest) else {
                throw PhysicalDesignStandardLayoutExportError.sourceIdentityMismatch("Snapshot and retained request require identical manifest and complete process asset references.")
            }
            for reference in [request.pdk.manifest] + request.processAssets.values.map(\.reference) {
                guard request.inputs.contains(reference), request.inputBindings.filter({ $0.reference == reference }).count == 1 else {
                    throw PhysicalDesignStandardLayoutExportError.sourceIdentityMismatch("Each source requires one exact retained input binding and provenance reference.")
                }
            }
            let manifest = try request.requireBinding(for: request.pdk.manifest)
            guard manifest.descriptor.role == .input, manifest.descriptor.format == .json else {
                throw PhysicalDesignStandardLayoutExportError.sourceIdentityMismatch("The retained manifest requires an input JSON binding.")
            }
            let store = PhysicalDesignExportReadStore(store: artifactStore, limit: limits.maximumInputByteCount)
            // Bound caller-owned text before the shared writer interpolates snapshot identifiers.
            try store.charge(UInt64(snapshot.topCell.utf8.count))
            for row in snapshot.rows { try store.charge(UInt64(row.id.utf8.count)); try store.charge(UInt64(row.siteName?.utf8.count ?? 0)) }
            for cell in snapshot.cells { try store.charge(UInt64(cell.id.utf8.count)); try store.charge(UInt64(cell.master.utf8.count)) }
            for pin in snapshot.pins { try store.charge(UInt64(pin.name.utf8.count)); try store.charge(UInt64(pin.cellID?.utf8.count ?? 0)) }
            for net in snapshot.nets { try store.charge(UInt64(net.id.utf8.count)) }
            for via in snapshot.vias { try store.charge(UInt64(via.master?.utf8.count ?? 0)) }
            guard let inputs = try await PhysicalDesignProcessInputs.load(request: request, store: store), !inputs.cellViews.isEmpty else {
                throw PhysicalDesignStandardLayoutExportError.invalidSource("Source-bound export requires selected technology and cell views.")
            }
            try PhysicalDesignExportGeometryBudget.validate(inputs: inputs, snapshot: snapshot, limit: limits.maximumGeometryRecordCount)
            try Task.checkCancellation()
            let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: snapshot.unitsPerMicron)
            try Task.checkCancellation()
            do { try geometry.validate(snapshot) }
            catch { throw PhysicalDesignStandardLayoutExportError.invalidSnapshot(error.localizedDescription) }
            try Task.checkCancellation()
            let text: String
            do { text = try PhysicalDesignDEFWriter().write(snapshot, processGeometry: geometry, maximumOutputByteCount: limits.maximumOutputByteCount) }
            catch let error as PhysicalDesignStandardLayoutExportError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { throw PhysicalDesignStandardLayoutExportError.encodingFailed(error.localizedDescription) }
            try Task.checkCancellation()
            return Data(text.utf8)
        } catch let error as PhysicalDesignStandardLayoutExportError { throw error }
        catch is CancellationError { throw PhysicalDesignStandardLayoutExportError.cancelled }
        catch { throw PhysicalDesignStandardLayoutExportError.invalidSource(error.localizedDescription) }
    }
}
