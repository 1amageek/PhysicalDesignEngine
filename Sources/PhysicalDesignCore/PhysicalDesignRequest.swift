import Foundation
import XcircuitePackage
import LogicIR
import TimingCore
import PDKCore

public struct PhysicalDesignRequest: XcircuiteEngineRequest {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var inputs: [XcircuiteFileReference]

    public var design: LogicDesignReference
    public var constraints: TimingConstraintReference
    public var pdk: PDKReference
    public var inputLayout: PhysicalDesignReference?
    public var stage: PhysicalDesignStage
    public var configuration: PhysicalDesignConfiguration
    public var initialSnapshot: PhysicalDesignSnapshot?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case inputs
        case design
        case constraints
        case pdk
        case inputLayout
        case stage
        case configuration
        case initialSnapshot
    }

    public init(
        runID: String,
        inputs: [XcircuiteFileReference],
        design: LogicDesignReference,
        constraints: TimingConstraintReference,
        pdk: PDKReference,
        inputLayout: PhysicalDesignReference? = nil,
        stage: PhysicalDesignStage = .floorplan,
        configuration: PhysicalDesignConfiguration = .default,
        initialSnapshot: PhysicalDesignSnapshot? = nil
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        runID = try container.decode(String.self, forKey: .runID)
        inputs = try container.decode([XcircuiteFileReference].self, forKey: .inputs)
        design = try container.decode(LogicDesignReference.self, forKey: .design)
        constraints = try container.decode(TimingConstraintReference.self, forKey: .constraints)
        pdk = try container.decode(PDKReference.self, forKey: .pdk)
        inputLayout = try container.decodeIfPresent(PhysicalDesignReference.self, forKey: .inputLayout)
        stage = try container.decodeIfPresent(PhysicalDesignStage.self, forKey: .stage) ?? .floorplan
        configuration = try container.decodeIfPresent(PhysicalDesignConfiguration.self, forKey: .configuration) ?? .default
        initialSnapshot = try container.decodeIfPresent(PhysicalDesignSnapshot.self, forKey: .initialSnapshot)
    }
}
