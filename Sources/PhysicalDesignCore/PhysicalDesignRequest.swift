import Foundation
import CircuiteFoundation
import LogicIR
import TimingCore
import PDKCore

public struct PhysicalDesignRequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var runID: String
    public var inputs: [ArtifactReference]

    public var design: LogicDesignReference
    public var constraints: TimingConstraintReference
    public var pdk: PDKReference
    public var inputLayout: PhysicalDesignReference?
    public var stage: PhysicalDesignStage
    public var configuration: PhysicalDesignConfiguration
    public var initialSnapshot: PhysicalDesignSnapshot?
    public var executionIntent: PhysicalDesignExecutionIntent
    public var clockTimingModel: PhysicalDesignClockTimingModelReference?

    public init(
        runID: String,
        inputs: [ArtifactReference],
        design: LogicDesignReference,
        constraints: TimingConstraintReference,
        pdk: PDKReference,
        inputLayout: PhysicalDesignReference? = nil,
        stage: PhysicalDesignStage = .floorplan,
        configuration: PhysicalDesignConfiguration = .default,
        initialSnapshot: PhysicalDesignSnapshot? = nil,
        executionIntent: PhysicalDesignExecutionIntent = .geometrySmoke,
        clockTimingModel: PhysicalDesignClockTimingModelReference? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.inputs = inputs
        self.design = design
        self.constraints = constraints
        self.pdk = pdk
        self.inputLayout = inputLayout
        self.stage = stage
        self.configuration = configuration
        self.initialSnapshot = initialSnapshot
        self.executionIntent = executionIntent
        self.clockTimingModel = clockTimingModel
    }

}
