import Foundation
import Testing
@testable import PhysicalDesignCore

@Suite("Physical-design authority boundary")
struct ProductionEvidenceTests {
    @Test("request schema contains execution inputs but no authorization record")
    func requestHasNoAuthorizationRecord() throws {
        let request = PhysicalDesignFixtureFactory.request(
            stage: .placement,
            snapshot: PhysicalDesignFixtureFactory.snapshot()
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        #expect(object["productionEvidence"] == nil)
        #expect(object["approval"] == nil)
        #expect(object["releaseGate"] == nil)
    }

    @Test("execution intent only selects physical analysis fidelity")
    func executionIntentIsAnalysisScope() {
        #expect(PhysicalDesignExecutionIntent.allCasesForTesting == [
            .geometrySmoke,
            .characterizedTiming,
        ])
    }

    @Test("successful native execution emits observations without release authorization")
    func resultDoesNotAuthorizeRelease() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let request = PhysicalDesignFixtureFactory.request(
            stage: .placement,
            snapshot: PhysicalDesignFixtureFactory.snapshot()
        )

        let result = try await NativePhysicalDesignExecutor(artifactStore: store).execute(request)

        #expect(result.status == .completed)
        #expect(result.payload.claims.production == .blocked)
    }

    @Test("production implementation remains a typed unsupported capability")
    func productionImplementationFailsClosed() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        var request = PhysicalDesignFixtureFactory.request(
            stage: .placement,
            snapshot: PhysicalDesignFixtureFactory.snapshot()
        )
        request.executionIntent = .productionImplementation

        let result = try await NativePhysicalDesignExecutor(artifactStore: store).execute(request)

        #expect(result.status == .blocked)
        #expect(result.payload.claims.production == .blocked)
        #expect(result.diagnostics.contains {
            $0.severity == .error
                && $0.code.rawValue == "native_production_implementation_unsupported"
        })
    }
}

private extension PhysicalDesignExecutionIntent {
    static var allCasesForTesting: [Self] {
        [.geometrySmoke, .characterizedTiming]
    }
}
