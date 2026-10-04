import Foundation
import PDKCore
import PEXCore
import TimingCore

public struct LocalPhysicalDesignClockTimingModelLoader: PhysicalDesignClockTimingModelLoading {
    public let maximumModelBytes: Int
    public init(maximumModelBytes: Int = 16 * 1024 * 1024) { self.maximumModelBytes = maximumModelBytes }
    public func load(_ reference: PhysicalDesignClockTimingModelReference, for snapshot: PhysicalDesignSnapshot,
                     from artifactStore: any PhysicalDesignArtifactStore) async throws -> PhysicalDesignClockCharacterization {
        do {
            let all = [reference.modelArtifact] + reference.sourceArtifacts
            guard maximumModelBytes > 0, reference.modelArtifact.reference.byteCount <= maximumModelBytes,
                  all.allSatisfy({ $0.descriptor.role == .input }), Set(all.map(\.reference.id)).count == all.count,
                  reference.modelArtifact.descriptor.format == .json, reference.pdkManifestArtifact.descriptor.format == .json,
                  reference.rcModelArtifact.descriptor.format == .json, reference.cellLibraryArtifact.descriptor.format == .liberty else { throw invalid("source format/role/model byte ceiling") }
            let model = try PhysicalDesignJSONCodec().decode(PhysicalDesignClockTimingModel.self, from: await artifactStore.read(reference.modelArtifact))
            try model.validate(against: reference)
            var remaining = model.numerics.maximumInputBytes
            for binding in all {
                guard let count = Int(exactly: binding.reference.byteCount), count <= remaining else { throw invalid("source byte budget") }
                remaining -= count
            }
            let manifest = try PDKManifestCodec.decode(data: await artifactStore.read(reference.pdkManifestArtifact))
            guard manifest.processID == model.processID, manifest.version == model.pdkVersion,
                  manifest.corners.filter({ $0.cornerID == model.cornerID }).count == 1,
                  let selected = manifest.corners.first(where: { $0.cornerID == model.cornerID }), selected.rcCorner == model.rcCornerID else { throw invalid("exact manifest corner") }
            for (id, binding) in [(model.libertyAssetID, reference.cellLibraryArtifact), (model.rcAssetID, reference.rcModelArtifact)] {
                let assets = manifest.assets.filter { $0.assetID == id }
                guard selected.assetIDs.contains(id), assets.count == 1, let asset = assets.first,
                      asset.format == binding.descriptor.format, asset.kind == binding.descriptor.kind,
                      asset.role == (id == model.libertyAssetID ? .liberty : .extraction),
                      asset.sha256?.lowercased() == binding.reference.digest.hexadecimalValue,
                      asset.byteCount.flatMap(UInt64.init(exactly:)) == binding.reference.byteCount else { throw invalid("corner asset \(id)") }
            }
            let technology = try PhysicalDesignJSONCodec().decode(TechnologyIR.self, from: await artifactStore.read(reference.rcModelArtifact))
            guard technology.processName == model.processID else { throw invalid("RC process") }
            let corner = PEXCorner(id: .init(model.rcCornerID), name: model.rcCornerID, temperature: selected.pvt.temperatureCelsius,
                                   voltage: selected.pvt.voltage, parameters: model.rcParameters)
            let electrical = try technology.electricalModel(for: corner)
            guard Set(electrical.calibrationArtifacts) == Set(reference.calibrationArtifacts.map(\.reference.id)) else { throw invalid("RC calibration input coverage") }
            for binding in reference.calibrationArtifacts { try Task.checkCancellation(); _ = try await artifactStore.read(binding) }
            let pins = Dictionary(uniqueKeysWithValues: snapshot.pins.map { ($0.id, $0) })
            let cells = Dictionary(uniqueKeysWithValues: snapshot.cells.map { ($0.id, $0) })
            var selectedCells = Set<String>()
            var propagationCells = Set<String>()
            guard Set(model.clocks.map(\.netID)) == Set(snapshot.nets.filter(\.isClock).map(\.id)), snapshot.clockTrees.isEmpty else { throw invalid("exact pre-CTS clock coverage") }
            for clock in model.clocks {
                guard let net = snapshot.nets.first(where: { $0.id == clock.netID }), net.isClock,
                      Set(net.pinIDs) == Set([clock.sourcePinID] + clock.sinkPinIDs),
                      pins[clock.sourcePinID]?.direction == "output", net.pinIDs.filter({ pins[$0]?.direction == "output" }).count == 1 else { throw invalid("sole clock source/net identity") }
                for id in clock.sinkPinIDs {
                    guard let pin = pins[id], pin.direction == "input", let cellID = pin.cellID, let cell = cells[cellID] else { throw invalid("source-bound sink \(id)") }
                    selectedCells.insert(cell.master)
                }
                if clock.topology != .direct, let master = clock.bufferMaster { selectedCells.insert(master); propagationCells.insert(master) }
                guard clock.rise.first?.voltage == 0, clock.rise.last?.voltage == selected.pvt.voltage,
                      clock.fall.first?.voltage == selected.pvt.voltage, clock.fall.last?.voltage == 0 else { throw invalid("explicit waveform supply/corner") }
            }
            let library = try LibertyParser().parseCharacterized(await artifactStore.read(reference.cellLibraryArtifact),
                                                                 cellNames: selectedCells.sorted(), propagationCellNames: propagationCells.sorted())
            for clock in model.clocks { for id in clock.sinkPinIDs {
                guard let pin = pins[id], let cellID = pin.cellID, let cell = cells[cellID],
                      try library.pinIsClock(cell: cell.master, pin: pin.name) else { throw invalid("declared Liberty clock sink") }
                _ = try library.pinCapacitance(cell: cell.master, pin: pin.name)
            } }
            return .init(model: model, library: library, technology: technology, corner: corner, reference: reference)
        } catch is CancellationError { throw CancellationError() }
        catch let error as PhysicalDesignStoreError { throw error }
        catch let error as PhysicalDesignClockTimingModelError { throw error }
        catch { throw invalid(String(describing: error)) }
    }
    private func invalid(_ field: String) -> PhysicalDesignClockTimingModelError { .invalidModel(field) }
}
