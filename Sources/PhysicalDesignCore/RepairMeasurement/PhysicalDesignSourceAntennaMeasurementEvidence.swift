import CircuiteFoundation
import DRCNative

/// Exact candidate observations; absence in an older manifest conveys no assessment.
public struct PhysicalDesignSourceAntennaMeasurementEvidence: Sendable, Hashable, Codable {
    public enum Coverage: String, Sendable, Hashable, Codable {
        case unassessed
        case clean
        case violated
    }
    public struct TerminalDeclaration: Sendable, Hashable, Codable {
        public let pinID: String
        public let masterName: String
        public let pinName: String
        public let source: ArtifactReference
        public let rawGateAreaSquareMicrons: Double?
        public let rawDiffusionAreaSquareMicrons: Double?
        public let reportedDiffusionAreaSquareMicrons: Double
        public let diffusionOrigin: String
    }
    /// Source material outside this ROUTING/CUT antenna model; conductivity and diffusion are not inferred.
    public struct NonConductorRecord: Sendable, Hashable, Codable {
        public enum SourceKind: String, Sendable, Hashable, Codable {
            case masterslice = "MASTERSLICE"
            case overlap = "OVERLAP"
            case implant = "IMPLANT"
        }
        public let recordID: String
        public let sourceID: String
        public let layerID: String
        public let sourceLayerName: String
        public let sourceKind: SourceKind
        public let netID: String?
        public let minX: Int64
        public let minY: Int64
        public let maxX: Int64
        public let maxY: Int64
    }
    public struct Check: Sendable, Hashable, Codable {
        public let phase: String
        public let snapshotDigest: ContentDigest
        public let terminalDeclarations: [TerminalDeclaration]
        public let nonConductorRecords: [NonConductorRecord]
        public let input: NativeSourceAntennaInput
        public let result: NativeSourceAntennaResult
    }
    public let profile: ArtifactReference?
    public let processManifest: ArtifactReference
    public let processAssets: [String: ArtifactReference]
    public let candidateSnapshotDigest: ContentDigest
    public let targetNetIDs: [String]
    public let coverage: Coverage
    public let checks: [Check]
}
