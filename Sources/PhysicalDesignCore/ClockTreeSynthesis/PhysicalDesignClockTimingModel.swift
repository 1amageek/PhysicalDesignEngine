import CoreSpice
import PEXNative

public struct PhysicalDesignClockTimingModel: Sendable, Codable {
    public enum Method: String, Sendable, Codable { case passiveLinearRCTransientV1 }
    public enum QuietBoundary: String, Sendable, Codable { case allOtherConductorsIdealReference }
    public enum Topology: String, Sendable, Codable { case direct, bufferEachSink, directThenBuffered }
    public struct Point: Sendable, Hashable, Codable {
        public var time: Double
        public var voltage: Double
        public init(time: Double, voltage: Double) { self.time = time; self.voltage = voltage }
    }
    public struct Clock: Sendable, Codable {
        public var netID: String
        public var sourcePinID: String
        public var sinkPinIDs: [String]
        public var rise: [Point]
        public var fall: [Point]
        public var topology: Topology
        public var bufferMaster: String?
        public var bufferRiseShape: [Point]
        public var bufferFallShape: [Point]
        public init(netID: String, sourcePinID: String, sinkPinIDs: [String], rise: [Point], fall: [Point], topology: Topology,
                    bufferMaster: String?, bufferRiseShape: [Point], bufferFallShape: [Point]) {
            self.netID = netID; self.sourcePinID = sourcePinID; self.sinkPinIDs = sinkPinIDs; self.rise = rise; self.fall = fall
            self.topology = topology; self.bufferMaster = bufferMaster; self.bufferRiseShape = bufferRiseShape; self.bufferFallShape = bufferFallShape
        }
    }
    public struct Electrode: Sendable, Codable {
        public var master: String
        public var pin: String
        public var faces: [NativePEXElectrodeFace]
        public init(master: String, pin: String, faces: [NativePEXElectrodeFace]) { self.master = master; self.pin = pin; self.faces = faces }
    }
    public struct Constraints: Sendable, Codable {
        public var maximumLatencySeconds: Double
        public var maximumSkewSeconds: Double
        public var maximumSlewSeconds: Double
        public var maximumLoadFarads: Double
        public init(maximumLatencySeconds: Double, maximumSkewSeconds: Double, maximumSlewSeconds: Double, maximumLoadFarads: Double) {
            self.maximumLatencySeconds = maximumLatencySeconds; self.maximumSkewSeconds = maximumSkewSeconds
            self.maximumSlewSeconds = maximumSlewSeconds; self.maximumLoadFarads = maximumLoadFarads
        }
    }
    public static let currentSchemaVersion = 3
    public var schemaVersion: Int
    public var processID: String
    public var pdkVersion: String
    public var cornerID: String
    public var rcCornerID: String
    public var libertyAssetID: String
    public var rcAssetID: String
    public var rcParameters: [String: String]
    public var pdkManifestDigest: String
    public var rcModelDigest: String
    public var cellLibraryDigest: String
    public var method: Method
    public var quietBoundary: QuietBoundary
    public var clocks: [Clock]
    public var electrodes: [Electrode]
    /// Nil preserves the absence of this table in legacy cell-root-only schema 2.
    public var topPortElectrodes: [PhysicalDesignClockTopPortElectrode]?
    public var constraints: Constraints
    public var numerics: PhysicalDesignClockNumerics
    public init(processID: String, pdkVersion: String, cornerID: String, rcCornerID: String, libertyAssetID: String, rcAssetID: String, rcParameters: [String: String],
                pdkManifestDigest: String, rcModelDigest: String, cellLibraryDigest: String, method: Method,
                quietBoundary: QuietBoundary, clocks: [Clock], electrodes: [Electrode], constraints: Constraints, numerics: PhysicalDesignClockNumerics, topPortElectrodes: [PhysicalDesignClockTopPortElectrode] = []) {
        self.schemaVersion = Self.currentSchemaVersion; self.processID = processID; self.pdkVersion = pdkVersion; self.cornerID = cornerID; self.rcCornerID = rcCornerID
        self.libertyAssetID = libertyAssetID; self.rcAssetID = rcAssetID; self.rcParameters = rcParameters; self.pdkManifestDigest = pdkManifestDigest
        self.rcModelDigest = rcModelDigest; self.cellLibraryDigest = cellLibraryDigest; self.method = method; self.quietBoundary = quietBoundary
        self.clocks = clocks; self.electrodes = electrodes; self.topPortElectrodes = topPortElectrodes; self.constraints = constraints; self.numerics = numerics
    }
    public func validate(against reference: PhysicalDesignClockTimingModelReference) throws {
        guard (schemaVersion == Self.currentSchemaVersion && topPortElectrodes != nil)
                || (schemaVersion == 2 && numerics.captureLimits == nil
                    && (topPortElectrodes == nil || topPortElectrodes?.isEmpty == true)) else {
            throw PhysicalDesignClockTimingModelError.invalidModel("clock schema or legacy top-port electrode data")
        }
        guard processID == reference.processID,
              pdkVersion == reference.pdkVersion, cornerID == reference.cornerID else { throw PhysicalDesignClockTimingModelError.invalidModel("schema/process/version/corner") }
        for (digest, binding) in [(pdkManifestDigest, reference.pdkManifestArtifact), (rcModelDigest, reference.rcModelArtifact), (cellLibraryDigest, reference.cellLibraryArtifact)] {
            guard digest.lowercased() == binding.reference.digest.hexadecimalValue, binding.reference.digest.algorithm == .sha256 else {
                throw PhysicalDesignClockTimingModelError.sourceArtifactMismatch(binding.reference.id.description)
            }
        }
        try numerics.validate()
        guard !clocks.isEmpty, Set(clocks.map(\.netID)).count == clocks.count, !libertyAssetID.isEmpty, !rcAssetID.isEmpty, !rcCornerID.isEmpty,
              libertyAssetID != rcAssetID, clocks.count <= numerics.maximumProjectionRecords,
              !electrodes.isEmpty, electrodes.count <= numerics.maximumProjectionRecords,
              Set(electrodes.map { $0.master + "\u{0}" + $0.pin }).count == electrodes.count,
              electrodes.allSatisfy({ !$0.master.isEmpty && !$0.pin.isEmpty && !$0.faces.isEmpty }) else {
            throw PhysicalDesignClockTimingModelError.invalidModel("clock/source/electrode identity or input budget")
        }
        guard [constraints.maximumLatencySeconds, constraints.maximumSkewSeconds, constraints.maximumSlewSeconds,
               constraints.maximumLoadFarads].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw PhysicalDesignClockTimingModelError.invalidModel("constraint units/ranges")
        }
        var sourceRecords = 0
        func charge(_ count: Int) throws {
            try Task.checkCancellation()
            let sum = sourceRecords.addingReportingOverflow(count)
            guard count >= 0, !sum.overflow, sum.partialValue <= numerics.maximumProjectionRecords else {
                throw PhysicalDesignClockTimingModelError.invalidModel("source record budget")
            }
            sourceRecords = sum.partialValue
        }
        for electrode in electrodes { try charge(1); try charge(electrode.faces.count) }
        var topPinIDs = Set<String>()
        for electrode in topPortElectrodes ?? [] {
            try charge(1); try charge(electrode.faces.count)
            guard !electrode.pinID.isEmpty, !electrode.faces.isEmpty,
                  topPinIDs.insert(electrode.pinID).inserted else {
                throw PhysicalDesignClockTimingModelError.invalidModel("top-port electrode identity or faces")
            }
        }
        for clock in clocks {
            try charge(1); try charge(clock.sinkPinIDs.count)
            for count in [clock.rise.count, clock.fall.count, clock.bufferRiseShape.count, clock.bufferFallShape.count] { try charge(count) }
            guard !clock.netID.isEmpty, !clock.sourcePinID.isEmpty, !clock.sinkPinIDs.isEmpty,
                  Set(clock.sinkPinIDs).count == clock.sinkPinIDs.count, !clock.sinkPinIDs.contains(clock.sourcePinID) else {
                throw PhysicalDesignClockTimingModelError.invalidModel("clock pin identity")
            }
            try PhysicalDesignClockWaveform.validate(clock.rise, rising: true, horizon: numerics.stopTimeSeconds)
            try PhysicalDesignClockWaveform.validate(clock.fall, rising: false, horizon: numerics.stopTimeSeconds)
            if clock.topology != .direct {
                guard let master = clock.bufferMaster, !master.isEmpty else { throw PhysicalDesignClockTimingModelError.invalidModel("explicit buffer master") }
                try PhysicalDesignClockWaveform.validate(clock.bufferRiseShape, rising: true, horizon: 1)
                try PhysicalDesignClockWaveform.validate(clock.bufferFallShape, rising: false, horizon: 1)
            }
        }
    }
}
