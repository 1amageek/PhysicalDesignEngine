import Foundation
import CircuiteFoundation
import LogicIR
import LogicDesignSerialization
import PDKCore

public struct PhysicalDesignRequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 8

    public var schemaVersion: Int
    public var runID: String
    public var inputs: [ArtifactReference]
    public var inputBindings: [PhysicalDesignArtifactBinding]
    public var processAssets: [String: PhysicalDesignArtifactBinding]

    public var design: LogicDesignReference
    public var constraints: PhysicalDesignArtifactBinding
    public var requestedModeIDs: [String]
    public var pdk: PDKReference
    public var inputLayout: PhysicalDesignReference?
    public var stage: PhysicalDesignStage
    public var configuration: PhysicalDesignConfiguration
    public var initialSnapshot: PhysicalDesignSnapshot?
    public var executionIntent: PhysicalDesignExecutionIntent
    public var placementTimingProfile: PhysicalDesignPlacementTimingReference?
    public var clockTimingModel: PhysicalDesignClockTimingModelReference?
    public var repairMeasurementProfile: PhysicalDesignRepairMeasurementReference?
    public var productionConfiguration: PhysicalDesignProductionConfiguration?

    public init(
        runID: String,
        inputBindings: [PhysicalDesignArtifactBinding],
        design: LogicDesignReference,
        constraints: PhysicalDesignArtifactBinding,
        requestedModeIDs: [String],
        pdk: PDKReference,
        inputLayout: PhysicalDesignReference? = nil,
        stage: PhysicalDesignStage = .floorplan,
        configuration: PhysicalDesignConfiguration = .default,
        initialSnapshot: PhysicalDesignSnapshot? = nil,
        executionIntent: PhysicalDesignExecutionIntent = .geometrySmoke,
        clockTimingModel: PhysicalDesignClockTimingModelReference? = nil,
        placementTimingProfile: PhysicalDesignPlacementTimingReference? = nil,
        productionConfiguration: PhysicalDesignProductionConfiguration? = nil,
        processAssets: [String: PhysicalDesignArtifactBinding] = [:],
        repairMeasurementProfile: PhysicalDesignRepairMeasurementReference? = nil
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
        self.placementTimingProfile = placementTimingProfile
        self.productionConfiguration = productionConfiguration
        self.processAssets = processAssets
        self.repairMeasurementProfile = repairMeasurementProfile
        let timingArtifacts = clockTimingModel.map { [$0.modelArtifact] + $0.sourceArtifacts } ?? []
        let productionArtifacts = productionConfiguration?.inputArtifacts ?? []
        let prerequisiteBindings = [constraints]
            + (inputLayout.map { [$0.layoutArtifact] } ?? [])
            + timingArtifacts
            + (placementTimingProfile.map { [$0.artifact] } ?? [])
            + (repairMeasurementProfile.map { [$0.artifact] } ?? [])
            + productionArtifacts
            + inputBindings
            + processAssets.keys.sorted().compactMap { processAssets[$0] }
        var retainedBindings: [PhysicalDesignArtifactBinding] = []
        for binding in prerequisiteBindings where !retainedBindings.contains(binding) {
            retainedBindings.append(binding)
        }
        self.inputBindings = retainedBindings
        let prerequisites = [design.artifact, pdk.manifest]
            + retainedBindings.map(\.reference)
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
        case inputBindings
        case processAssets
        case design
        case constraints
        case requestedModeIDs
        case pdk
        case inputLayout
        case stage
        case configuration
        case initialSnapshot
        case executionIntent
        case placementTimingProfile
        case clockTimingModel
        case repairMeasurementProfile
        case productionConfiguration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion || schemaVersion == 7 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported physical design request schema version \(schemaVersion)."
            )
        }
        self.init(
            runID: try container.decode(String.self, forKey: .runID),
            inputBindings: try container.decode([PhysicalDesignArtifactBinding].self, forKey: .inputBindings),
            design: try container.decode(LogicDesignReference.self, forKey: .design),
            constraints: try container.decode(PhysicalDesignArtifactBinding.self, forKey: .constraints),
            requestedModeIDs: try container.decode([String].self, forKey: .requestedModeIDs),
            pdk: try container.decode(PDKReference.self, forKey: .pdk),
            inputLayout: try container.decodeIfPresent(PhysicalDesignReference.self, forKey: .inputLayout),
            stage: try container.decode(PhysicalDesignStage.self, forKey: .stage),
            configuration: try container.decode(PhysicalDesignConfiguration.self, forKey: .configuration),
            initialSnapshot: try container.decodeIfPresent(PhysicalDesignSnapshot.self, forKey: .initialSnapshot),
            executionIntent: try container.decode(PhysicalDesignExecutionIntent.self, forKey: .executionIntent),
            clockTimingModel: try container.decodeIfPresent(PhysicalDesignClockTimingModelReference.self, forKey: .clockTimingModel),
            placementTimingProfile: try container.decodeIfPresent(PhysicalDesignPlacementTimingReference.self, forKey: .placementTimingProfile),
            productionConfiguration: try container.decodeIfPresent(PhysicalDesignProductionConfiguration.self, forKey: .productionConfiguration),
            processAssets: try container.decode([String: PhysicalDesignArtifactBinding].self, forKey: .processAssets),
            repairMeasurementProfile: try container.decodeIfPresent(PhysicalDesignRepairMeasurementReference.self, forKey: .repairMeasurementProfile)
        )
        self.schemaVersion = schemaVersion
        guard supportsExecutionSchema else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                debugDescription: "An explicit source routing width policy requires request schema 8.")
        }
        let declaredInputs = try container.decode([ArtifactReference].self, forKey: .inputs)
        guard declaredInputs.count == inputs.count, Set(declaredInputs) == Set(inputs) else {
            throw DecodingError.dataCorruptedError(forKey: .inputs, in: container,
                debugDescription: "Declared inputs must match the exact request prerequisites.")
        }
    }

    var supportsExecutionSchema: Bool {
        schemaVersion == Self.currentSchemaVersion
            || (schemaVersion == 7 && configuration.implementationConstraints?.sourceRoutingWidthPolicy == nil)
    }

    public func requireBinding(
        for reference: ArtifactReference
    ) throws -> PhysicalDesignArtifactBinding {
        try PhysicalDesignArtifactBinding.require(reference, in: inputBindings)
    }
}
