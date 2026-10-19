import CircuiteFoundation

/// Transported provenance; decoding this value does not perform or authorize adoption.
public struct PhysicalDesignRoutingSourceAdoptionLineage: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let parent: PhysicalDesignReference
    public let oldManifest: ArtifactReference
    public let newManifest: ArtifactReference
    public let oldAssets: [String: ArtifactReference]
    public let newAssets: [String: ArtifactReference]
    public let checkedFactIDs: [String]
    public let addedLayerIDs: [String]
    public let addedTrackIDs: [String]

    init(parent: PhysicalDesignReference, oldManifest: ArtifactReference, newManifest: ArtifactReference,
         oldAssets: [String: ArtifactReference], newAssets: [String: ArtifactReference],
         checkedFactIDs: [String], addedLayerIDs: [String], addedTrackIDs: [String]) {
        schemaVersion = 1; self.parent = parent; self.oldManifest = oldManifest; self.newManifest = newManifest
        self.oldAssets = oldAssets; self.newAssets = newAssets; self.checkedFactIDs = checkedFactIDs
        self.addedLayerIDs = addedLayerIDs; self.addedTrackIDs = addedTrackIDs
    }
}
