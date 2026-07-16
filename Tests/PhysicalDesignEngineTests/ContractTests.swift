import Testing
@testable import PhysicalDesignCore
@testable import FloorplanEngine
@testable import PlacementEngine
@testable import CTSEngine
@testable import RoutingEngine
@testable import PhysicalECO
@testable import PhysicalDFM
@testable import PhysicalDesignEngine

@Suite("PhysicalDesignEngine contract")
struct ContractTests {
    @Test("contract version reflects the typed trust boundary")
    func contractVersion() {
        #expect(PhysicalDesignEngineAPI.contractVersion == 2)
        #expect(PhysicalDesignEngineAPI.nativeCapability.supportedExecutionIntents == [
            .geometrySmoke,
            .characterizedTiming,
        ])
        #expect(PhysicalDesignEngineAPI.nativeCapability.supportedExecutionIntents == [.geometrySmoke, .characterizedTiming])
    }
}
