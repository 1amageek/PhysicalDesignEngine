import CircuiteFoundation
import Foundation

public struct PhysicalDesignClockTimingModelReference: Sendable, Hashable, Codable {
    public var modelArtifact: ArtifactReference
    public var pdkManifestArtifact: ArtifactReference
    public var rcModelArtifact: ArtifactReference
    public var cellLibraryArtifact: ArtifactReference
    public var processID: String
    public var pdkVersion: String
    public var cornerID: String

    public init(
        modelArtifact: ArtifactReference,
        pdkManifestArtifact: ArtifactReference,
        rcModelArtifact: ArtifactReference,
        cellLibraryArtifact: ArtifactReference,
        processID: String,
        pdkVersion: String,
        cornerID: String
    ) {
        self.modelArtifact = modelArtifact
        self.pdkManifestArtifact = pdkManifestArtifact
        self.rcModelArtifact = rcModelArtifact
        self.cellLibraryArtifact = cellLibraryArtifact
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.cornerID = cornerID
    }

    public var sourceArtifacts: [ArtifactReference] {
        [pdkManifestArtifact, rcModelArtifact, cellLibraryArtifact]
    }
}
