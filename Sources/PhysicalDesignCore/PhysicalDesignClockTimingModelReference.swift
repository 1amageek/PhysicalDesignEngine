import CircuiteFoundation
import Foundation

public struct PhysicalDesignClockTimingModelReference: Sendable, Hashable, Codable {
    public var modelArtifact: PhysicalDesignArtifactBinding
    public var pdkManifestArtifact: PhysicalDesignArtifactBinding
    public var rcModelArtifact: PhysicalDesignArtifactBinding
    public var cellLibraryArtifact: PhysicalDesignArtifactBinding
    public var processID: String
    public var pdkVersion: String
    public var cornerID: String

    public init(
        modelArtifact: PhysicalDesignArtifactBinding,
        pdkManifestArtifact: PhysicalDesignArtifactBinding,
        rcModelArtifact: PhysicalDesignArtifactBinding,
        cellLibraryArtifact: PhysicalDesignArtifactBinding,
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

    public var sourceArtifacts: [PhysicalDesignArtifactBinding] {
        [pdkManifestArtifact, rcModelArtifact, cellLibraryArtifact]
    }
}
