import CircuiteFoundation
import Foundation

public struct PhysicalDesignProcessEvidence: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let runID: String
    public let stage: PhysicalDesignStage
    public let backendID: String
    public let executable: PhysicalDesignExecutableReference
    public let observedVersion: String
    public let invocation: ExecutionInvocation
    public let environment: ExecutionEnvironmentFingerprint
    public let inputs: [ArtifactReference]
    public let outputs: [ArtifactReference]
    public let standardOutput: ArtifactReference
    public let standardError: ArtifactReference
    public let generatedScript: ArtifactReference
    public let termination: PhysicalDesignProcessTermination
    public let exitCode: Int32?
    public let startedAt: Date
    public let completedAt: Date

    public init(
        runID: String,
        stage: PhysicalDesignStage,
        backendID: String,
        executable: PhysicalDesignExecutableReference,
        observedVersion: String,
        invocation: ExecutionInvocation,
        environment: ExecutionEnvironmentFingerprint,
        inputs: [ArtifactReference],
        outputs: [ArtifactReference],
        standardOutput: ArtifactReference,
        standardError: ArtifactReference,
        generatedScript: ArtifactReference,
        termination: PhysicalDesignProcessTermination,
        exitCode: Int32?,
        startedAt: Date,
        completedAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.stage = stage
        self.backendID = backendID
        self.executable = executable
        self.observedVersion = observedVersion
        self.invocation = invocation
        self.environment = environment
        self.inputs = inputs
        self.outputs = outputs
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.generatedScript = generatedScript
        self.termination = termination
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported physical design process evidence schema version \(schemaVersion)."
            )
        }
        self.schemaVersion = schemaVersion
        runID = try container.decode(String.self, forKey: .runID)
        stage = try container.decode(PhysicalDesignStage.self, forKey: .stage)
        backendID = try container.decode(String.self, forKey: .backendID)
        executable = try container.decode(PhysicalDesignExecutableReference.self, forKey: .executable)
        observedVersion = try container.decode(String.self, forKey: .observedVersion)
        invocation = try container.decode(ExecutionInvocation.self, forKey: .invocation)
        environment = try container.decode(ExecutionEnvironmentFingerprint.self, forKey: .environment)
        inputs = try container.decode([ArtifactReference].self, forKey: .inputs)
        outputs = try container.decode([ArtifactReference].self, forKey: .outputs)
        standardOutput = try container.decode(ArtifactReference.self, forKey: .standardOutput)
        standardError = try container.decode(ArtifactReference.self, forKey: .standardError)
        generatedScript = try container.decode(ArtifactReference.self, forKey: .generatedScript)
        termination = try container.decode(PhysicalDesignProcessTermination.self, forKey: .termination)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
    }
}
