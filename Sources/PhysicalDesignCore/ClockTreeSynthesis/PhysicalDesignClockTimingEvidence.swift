import CoreSpice

/// Model observations with explicit assumptions; no physical signoff qualification.
public struct PhysicalDesignClockTimingEvidence: Sendable, Hashable, Codable {
    public enum Qualification: String, Sendable, Hashable, Codable { case unqualifiedPhysicalSignoff }
    public enum DriverComposition: String, Sendable, Hashable, Codable { case nldmLumpedLoadCallerPWLDistributedPassiveRC }
    public struct Sink: Sendable, Hashable, Codable {
        public let pinID: String
        public let rootEdge: String
        public let sinkEdge: String
        public let arrivalSeconds: Double
        public let latencySeconds: Double
        public let slewSeconds: Double
        public let waveform: [PhysicalDesignClockTimingModel.Point]
    }
    public struct Net: Sendable, Hashable, Codable {
        public let netID: String
        public let loadFarads: Double
        public let maximumStepSeconds: Double
        public let crossingDifferenceSeconds: Double
        public let statistics: [TransientExecutionStatistics]
    }
    public struct Cell: Sendable, Hashable, Codable {
        public let master: String
        public let inputPinID: String
        public let outputPinID: String
        public let inputEdge: String
        public let outputEdge: String
        public let inputArrivalSeconds: Double
        public let inputSlewSeconds: Double
        public let outputLoadFarads: Double
        public let delaySeconds: Double
        public let outputSlewSeconds: Double
        public let prescribedOutputWaveform: [PhysicalDesignClockTimingModel.Point]
    }
    public let cells: [Cell]
    public let inputCapacitanceSources: [String: String]
    public let rcCornerID: String
    public let method: String
    public let quietBoundary: String
    public let driverAssumption: String
    public let driverComposition: DriverComposition
    public let qualification: Qualification
    public let constraintsSatisfied: Bool
    public let sinks: [Sink]
    public let nets: [Net]
    public let standardDefaultAttributes: [String]
    public let thresholdsPercent: [String: Double]
    public let meshCellCount: Int
    public let resistorCount: Int
    public let capacitorCount: Int
    public let electrodeContactCount: Int
}
