import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public enum PhysicalDesignEngineAPI {
    public static let contractVersion = 2

    public static let nativeCapability = PhysicalDesignCapability(
        engineID: "physical-design.native",
        contractVersion: contractVersion,
        supportedInputFormats: [.json, .def],
        supportedOutputFormats: [.json, .def],
        features: PhysicalDesignStage.allCases.map(\.rawValue),
        limitations: [
            "Native execution uses the canonical PhysicalDesignSnapshot JSON input model.",
            "DRC, LVS, PEX and timing remain independent verification oracles.",
            "Placement and routing are geometry-smoke heuristics, not production implementation.",
            "CTS timing requires PDK/RC/cell/corner-bound characterization artifacts.",
            "GDSII and OASIS stream-out require a process-qualified mask-data encoder."
        ],
        supportedExecutionIntents: [.geometrySmoke, .characterizedTiming]
    )
}
