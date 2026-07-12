import Foundation
import XcircuitePackage
import PhysicalDesignCore

public enum PhysicalDesignEngineAPI {
    public static let contractVersion = 1

    public static let nativeCapability = XcircuiteEngineCapability(
        engineID: "physical-design.native",
        contractVersion: contractVersion,
        supportedInputFormats: [.json],
        supportedOutputFormats: [.json, .def],
        features: PhysicalDesignStage.allCases.map(\.rawValue),
        limitations: [
            "Native execution uses the canonical PhysicalDesignSnapshot JSON input model.",
            "DRC, LVS, PEX and timing remain independent verification oracles.",
            "GDSII and OASIS stream-out require an external qualified adapter."
        ]
    )
}
