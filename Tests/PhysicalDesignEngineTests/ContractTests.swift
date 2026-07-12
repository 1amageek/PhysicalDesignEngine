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
    @Test("contract version starts at one")
    func contractVersion() {
        #expect(PhysicalDesignEngineAPI.contractVersion == 1)
    }
}

