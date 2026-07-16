import Foundation

public struct PhysicalDesignClockTimingModel: Sendable, Hashable, Codable {
    public struct WireDelaySample: Sendable, Hashable, Codable {
        public var pathLengthDBU: Int64
        public var delayPS: Double

        public init(pathLengthDBU: Int64, delayPS: Double) {
            self.pathLengthDBU = pathLengthDBU
            self.delayPS = delayPS
        }
    }

    public struct CellDelay: Sendable, Hashable, Codable {
        public var master: String
        public var delayPS: Double

        public init(master: String, delayPS: Double) {
            self.master = master
            self.delayPS = delayPS
        }
    }

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var processID: String
    public var pdkVersion: String
    public var cornerID: String
    public var pdkManifestDigest: String
    public var rcModelDigest: String
    public var cellLibraryDigest: String
    public var wireDelaySamples: [WireDelaySample]
    public var cellDelays: [CellDelay]

    public init(
        processID: String,
        pdkVersion: String,
        cornerID: String,
        pdkManifestDigest: String,
        rcModelDigest: String,
        cellLibraryDigest: String,
        wireDelaySamples: [WireDelaySample],
        cellDelays: [CellDelay]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.cornerID = cornerID
        self.pdkManifestDigest = pdkManifestDigest
        self.rcModelDigest = rcModelDigest
        self.cellLibraryDigest = cellLibraryDigest
        self.wireDelaySamples = wireDelaySamples.sorted { $0.pathLengthDBU < $1.pathLengthDBU }
        self.cellDelays = cellDelays.sorted { $0.master < $1.master }
    }

    public func validate(against reference: PhysicalDesignClockTimingModelReference) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PhysicalDesignClockTimingModelError.invalidModel("unsupported schema version")
        }
        guard processID == reference.processID,
              pdkVersion == reference.pdkVersion,
              cornerID == reference.cornerID else {
            throw PhysicalDesignClockTimingModelError.invalidModel("process, PDK version or corner identity mismatch")
        }
        guard reference.pdkManifestArtifact.digest.algorithm == .sha256,
              pdkManifestDigest.caseInsensitiveCompare(
                reference.pdkManifestArtifact.digest.hexadecimalValue
              ) == .orderedSame else {
            throw PhysicalDesignClockTimingModelError.sourceArtifactMismatch("PDK manifest")
        }
        guard reference.rcModelArtifact.digest.algorithm == .sha256,
              rcModelDigest.caseInsensitiveCompare(
                reference.rcModelArtifact.digest.hexadecimalValue
              ) == .orderedSame else {
            throw PhysicalDesignClockTimingModelError.sourceArtifactMismatch("RC model")
        }
        guard reference.cellLibraryArtifact.digest.algorithm == .sha256,
              cellLibraryDigest.caseInsensitiveCompare(
                reference.cellLibraryArtifact.digest.hexadecimalValue
              ) == .orderedSame else {
            throw PhysicalDesignClockTimingModelError.sourceArtifactMismatch("cell library")
        }
        guard !wireDelaySamples.isEmpty else {
            throw PhysicalDesignClockTimingModelError.invalidModel("wire delay samples are empty")
        }
        let lengths = wireDelaySamples.map(\.pathLengthDBU)
        guard lengths.allSatisfy({ $0 >= 0 }),
              Set(lengths).count == lengths.count,
              wireDelaySamples.allSatisfy({ $0.delayPS.isFinite && $0.delayPS >= 0 }) else {
            throw PhysicalDesignClockTimingModelError.invalidModel("wire delay samples are not finite, non-negative and unique")
        }
        for (lower, upper) in zip(wireDelaySamples, wireDelaySamples.dropFirst()) {
            guard upper.pathLengthDBU > lower.pathLengthDBU,
                  upper.delayPS >= lower.delayPS else {
                throw PhysicalDesignClockTimingModelError.invalidModel(
                    "wire delay samples must increase in path length without decreasing delay"
                )
            }
        }
        let masters = cellDelays.map(\.master)
        guard Set(masters).count == masters.count,
              cellDelays.allSatisfy({
                  !$0.master.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.delayPS.isFinite
                      && $0.delayPS >= 0
              }) else {
            throw PhysicalDesignClockTimingModelError.invalidModel("cell delay entries are invalid or duplicated")
        }
    }

    public func delayPS(pathLengthDBU: Int64, bufferMasters: [String]) throws -> Double {
        guard pathLengthDBU >= 0 else {
            throw PhysicalDesignClockTimingModelError.unsupportedPathLength(pathLengthDBU)
        }
        let sortedSamples = wireDelaySamples.sorted { $0.pathLengthDBU < $1.pathLengthDBU }
        guard let upperIndex = sortedSamples.firstIndex(where: { $0.pathLengthDBU >= pathLengthDBU }) else {
            throw PhysicalDesignClockTimingModelError.unsupportedPathLength(pathLengthDBU)
        }
        let upper = sortedSamples[upperIndex]
        let lower = upperIndex == 0
            ? WireDelaySample(pathLengthDBU: 0, delayPS: 0)
            : sortedSamples[upperIndex - 1]
        let wireDelay: Double
        if upper.pathLengthDBU == lower.pathLengthDBU {
            wireDelay = upper.delayPS
        } else {
            let fraction = Double(pathLengthDBU - lower.pathLengthDBU)
                / Double(upper.pathLengthDBU - lower.pathLengthDBU)
            wireDelay = lower.delayPS + fraction * (upper.delayPS - lower.delayPS)
        }
        let delayByMaster = Dictionary(uniqueKeysWithValues: cellDelays.map { ($0.master, $0.delayPS) })
        let cellDelay = try bufferMasters.reduce(0.0) { partial, master in
            guard let delay = delayByMaster[master] else {
                throw PhysicalDesignClockTimingModelError.missingCellDelay(master)
            }
            return partial + delay
        }
        return wireDelay + cellDelay
    }
}
