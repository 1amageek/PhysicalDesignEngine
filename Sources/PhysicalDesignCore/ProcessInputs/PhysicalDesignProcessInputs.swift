import CircuiteFoundation
import LEF
import PDKCore

struct PhysicalDesignProcessInputs: Sendable {
    let manifest: PDKManifest
    let technologyViews: [String: LEFDocument]
    let cellViews: [String: LEFDocument]

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
        return Self(manifest: manifest, technologyViews: technologyViews, cellViews: cellViews)
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
