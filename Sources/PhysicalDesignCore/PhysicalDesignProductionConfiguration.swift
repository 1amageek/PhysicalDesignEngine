import CircuiteFoundation
import Foundation

public struct PhysicalDesignProductionConfiguration: Sendable, Hashable, Codable {
    public let backendID: String
    public let executable: PhysicalDesignExecutableReference
    public let versionArguments: [String]
    public let technologyLEFs: [ArtifactReference]
    public let cellLEFs: [ArtifactReference]
    public let libertyLibraries: [ArtifactReference]
    public let synthesizedNetlist: ArtifactReference
    public let rcSetupScript: ArtifactReference
    public let stageScript: ArtifactReference
    public let cornerID: String
    public let timeoutSeconds: Double

    public init(
        backendID: String = "openroad",
        executable: PhysicalDesignExecutableReference,
        versionArguments: [String] = ["-version"],
        technologyLEFs: [ArtifactReference],
        cellLEFs: [ArtifactReference],
        libertyLibraries: [ArtifactReference],
        synthesizedNetlist: ArtifactReference,
        rcSetupScript: ArtifactReference,
        stageScript: ArtifactReference,
        cornerID: String,
        timeoutSeconds: Double = 300
    ) throws {
        guard !backendID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !backendID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PhysicalDesignProductionConfigurationError.invalidBackendID
        }
        guard !cornerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cornerID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PhysicalDesignProductionConfigurationError.invalidCornerID
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw PhysicalDesignProductionConfigurationError.invalidTimeout
        }
        guard !technologyLEFs.isEmpty else {
            throw PhysicalDesignProductionConfigurationError.missingTechnologyLEF
        }
        guard !cellLEFs.isEmpty else {
            throw PhysicalDesignProductionConfigurationError.missingCellLEF
        }
        guard !libertyLibraries.isEmpty else {
            throw PhysicalDesignProductionConfigurationError.missingLibertyLibrary
        }
        guard !versionArguments.isEmpty,
              !versionArguments.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else {
            throw PhysicalDesignProductionConfigurationError.invalidVersionArguments
        }

        let artifacts = technologyLEFs + cellLEFs + libertyLibraries
            + [synthesizedNetlist, rcSetupScript, stageScript]
        var paths = Set<String>()
        for artifact in artifacts {
            guard artifact.locator.role == .input,
                  artifact.digest.algorithm == .sha256,
                  artifact.byteCount > 0 else {
                throw PhysicalDesignProductionConfigurationError.invalidArtifact(artifact.path)
            }
            guard paths.insert(artifact.path).inserted else {
                throw PhysicalDesignProductionConfigurationError.duplicateArtifact(artifact.path)
            }
        }
        guard technologyLEFs.allSatisfy({ $0.format == .lef }) else {
            throw PhysicalDesignProductionConfigurationError.invalidArtifact("technology LEF format")
        }
        guard cellLEFs.allSatisfy({ $0.format == .lef }) else {
            throw PhysicalDesignProductionConfigurationError.invalidArtifact("cell LEF format")
        }
        guard libertyLibraries.allSatisfy({ $0.format == .liberty }) else {
            throw PhysicalDesignProductionConfigurationError.invalidArtifact("Liberty format")
        }
        guard synthesizedNetlist.format == .verilog || synthesizedNetlist.format == .systemVerilog else {
            throw PhysicalDesignProductionConfigurationError.invalidArtifact("synthesized netlist format")
        }
        guard rcSetupScript.format == .text || rcSetupScript.format == .raw else {
            throw PhysicalDesignProductionConfigurationError.invalidArtifact("RC setup script format")
        }
        guard stageScript.format == .text || stageScript.format == .raw else {
            throw PhysicalDesignProductionConfigurationError.invalidArtifact("stage script format")
        }

        self.backendID = backendID
        self.executable = executable
        self.versionArguments = versionArguments
        self.technologyLEFs = technologyLEFs
        self.cellLEFs = cellLEFs
        self.libertyLibraries = libertyLibraries
        self.synthesizedNetlist = synthesizedNetlist
        self.rcSetupScript = rcSetupScript
        self.stageScript = stageScript
        self.cornerID = cornerID
        self.timeoutSeconds = timeoutSeconds
    }

    public var inputArtifacts: [ArtifactReference] {
        technologyLEFs + cellLEFs + libertyLibraries
            + [synthesizedNetlist, rcSetupScript, stageScript]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            backendID: container.decode(String.self, forKey: .backendID),
            executable: container.decode(PhysicalDesignExecutableReference.self, forKey: .executable),
            versionArguments: container.decode([String].self, forKey: .versionArguments),
            technologyLEFs: container.decode([ArtifactReference].self, forKey: .technologyLEFs),
            cellLEFs: container.decode([ArtifactReference].self, forKey: .cellLEFs),
            libertyLibraries: container.decode([ArtifactReference].self, forKey: .libertyLibraries),
            synthesizedNetlist: container.decode(ArtifactReference.self, forKey: .synthesizedNetlist),
            rcSetupScript: container.decode(ArtifactReference.self, forKey: .rcSetupScript),
            stageScript: container.decode(ArtifactReference.self, forKey: .stageScript),
            cornerID: container.decode(String.self, forKey: .cornerID),
            timeoutSeconds: container.decode(Double.self, forKey: .timeoutSeconds)
        )
    }
}
