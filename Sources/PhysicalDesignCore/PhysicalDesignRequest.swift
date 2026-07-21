import Foundation
import CircuiteFoundation
import LogicIR
import PDKCore

public struct PhysicalDesignRequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var runID: String
    public var inputs: [ArtifactReference]

    public var design: LogicDesignReference
    public var constraints: ArtifactReference
    public var requestedModeIDs: [String]
    public var pdk: PDKReference
    public var inputLayout: PhysicalDesignReference?
    public var stage: PhysicalDesignStage
    public var configuration: PhysicalDesignConfiguration
    public var initialSnapshot: PhysicalDesignSnapshot?
    public var executionIntent: PhysicalDesignExecutionIntent
    public var clockTimingModel: PhysicalDesignClockTimingModelReference?
    public var productionConfiguration: PhysicalDesignProductionConfiguration?

    public init(
        runID: String,
        inputs: [ArtifactReference],
        design: LogicDesignReference,
        constraints: ArtifactReference,
        requestedModeIDs: [String],
        pdk: PDKReference,
        inputLayout: PhysicalDesignReference? = nil,
        stage: PhysicalDesignStage = .floorplan,
        configuration: PhysicalDesignConfiguration = .default,
        initialSnapshot: PhysicalDesignSnapshot? = nil,
        executionIntent: PhysicalDesignExecutionIntent = .geometrySmoke,
        clockTimingModel: PhysicalDesignClockTimingModelReference? = nil,
        productionConfiguration: PhysicalDesignProductionConfiguration? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.design = design
        self.constraints = constraints
        self.requestedModeIDs = requestedModeIDs
        self.pdk = pdk
        self.inputLayout = inputLayout
        self.stage = stage
        self.configuration = configuration
        self.initialSnapshot = initialSnapshot
        self.executionIntent = executionIntent
        self.clockTimingModel = clockTimingModel
        self.productionConfiguration = productionConfiguration
        let timingArtifacts = clockTimingModel.map { [$0.modelArtifact] + $0.sourceArtifacts } ?? []
        let productionArtifacts = productionConfiguration?.inputArtifacts ?? []
        let prerequisites = [design.artifact, constraints, pdk.manifest]
            + (inputLayout.map { [$0.layoutArtifact] } ?? [])
            + timingArtifacts
            + productionArtifacts
            + inputs
        var retainedInputs: [ArtifactReference] = []
        for artifact in prerequisites where !retainedInputs.contains(artifact) {
            retainedInputs.append(artifact)
        }
        self.inputs = retainedInputs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case inputs
        case design
        case constraints
        case requestedModeIDs
        case pdk
        case inputLayout
        case stage
        case configuration
        case initialSnapshot
        case executionIntent
        case clockTimingModel
        case productionConfiguration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported physical design request schema version \(schemaVersion)."
            )
        }
        self.init(
            runID: try container.decode(String.self, forKey: .runID),
            inputs: try container.decode([ArtifactReference].self, forKey: .inputs),
            design: try container.decode(LogicDesignReference.self, forKey: .design),
            constraints: try container.decode(ArtifactReference.self, forKey: .constraints),
            requestedModeIDs: try container.decode([String].self, forKey: .requestedModeIDs),
            pdk: try container.decode(PDKReference.self, forKey: .pdk),
            inputLayout: try container.decodeIfPresent(PhysicalDesignReference.self, forKey: .inputLayout),
            stage: try container.decode(PhysicalDesignStage.self, forKey: .stage),
            configuration: try container.decode(PhysicalDesignConfiguration.self, forKey: .configuration),
            initialSnapshot: try container.decodeIfPresent(PhysicalDesignSnapshot.self, forKey: .initialSnapshot),
            executionIntent: try container.decode(PhysicalDesignExecutionIntent.self, forKey: .executionIntent),
            clockTimingModel: try container.decodeIfPresent(PhysicalDesignClockTimingModelReference.self, forKey: .clockTimingModel),
            productionConfiguration: try container.decodeIfPresent(PhysicalDesignProductionConfiguration.self, forKey: .productionConfiguration)
        )
    }
}
