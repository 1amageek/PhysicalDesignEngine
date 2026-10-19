import Foundation
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Explicit source routing width policy", .timeLimit(.minutes(1)))
struct SourceRoutingWidthPolicyTests {
    @Test func legacyConstraintsRoundTrip() throws {
        let codec = PhysicalDesignJSONCodec()
        var value = PhysicalDesignImplementationConstraints(routeWidth: 170, sourceRoutingWidthPolicy: .sourceDefault)
        var object = try #require(JSONSerialization.jsonObject(with: codec.encode(value)) as? [String: Any])
        object.removeValue(forKey: "sourceRoutingWidthPolicy")
        let decoded = try codec.decode(PhysicalDesignImplementationConstraints.self, from: JSONSerialization.data(withJSONObject: object))
        value.sourceRoutingWidthPolicy = nil
        #expect(decoded == value && decoded.routeWidth == 170)
        #expect(try codec.decode(PhysicalDesignImplementationConstraints.self, from: codec.encode(decoded)) == decoded)
        #expect(PhysicalDesignImplementationConstraints.default.routeWidth == 100)
        #expect(PhysicalDesignImplementationConstraints.default.sourceRoutingWidthPolicy == nil)
    }

    @Test(arguments: ["unknown", "malformed"])
    func invalidPolicyDecode(_ reason: String) throws {
        let codec = PhysicalDesignJSONCodec()
        var object = try #require(JSONSerialization.jsonObject(with: codec.encode(PhysicalDesignImplementationConstraints.default)) as? [String: Any])
        if reason == "unknown" { object["sourceRoutingWidthPolicy"] = "futureWidth" }
        else { object["sourceRoutingWidthPolicy"] = 17 }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try codec.decode(PhysicalDesignImplementationConstraints.self, from: bytes) }
    }

    @Test(arguments: ["7-nil", "7-uniform", "7-source", "8-uniform", "8-source", "6-nil"])
    func requestSchemaAdmission(_ scenario: String) async throws {
        var request = PhysicalDesignFixtureFactory.request(stage: .floorplan,
            snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false, includeRoutes: false, includeVias: false))
        request.schemaVersion = scenario.hasPrefix("7") ? 7 : (scenario.hasPrefix("6") ? 6 : 8)
        var constraints = request.configuration.implementationConstraints ?? .default
        constraints.sourceRoutingWidthPolicy = scenario.hasSuffix("source") ? .sourceDefault : (scenario.hasSuffix("uniform") ? .uniform : nil)
        request.configuration.implementationConstraints = constraints
        let codec = PhysicalDesignJSONCodec(), bytes = try codec.encode(request)
        let admitted = scenario == "7-nil" || scenario.hasPrefix("8")
        if admitted {
            let decoded = try codec.decode(PhysicalDesignRequest.self, from: bytes)
            #expect(decoded.schemaVersion == request.schemaVersion && decoded.configuration == request.configuration)
            let retained = try codec.decode(PhysicalDesignRequest.self, from: codec.encode(decoded))
            #expect(retained.schemaVersion == request.schemaVersion)
        } else {
            #expect(throws: DecodingError.self) { try codec.decode(PhysicalDesignRequest.self, from: bytes) }
            let result = try await PhysicalDesignEngine(artifactStore: InMemoryPhysicalDesignArtifactStore()).execute(request)
            #expect(result.status == .blocked && result.artifactBindings.isEmpty)
            #expect(result.diagnostics.contains { $0.code.rawValue == "unsupported_request_schema" })
            let mutation = await PhysicalDesignNativeMutationEngine().apply(request, to: try #require(request.initialSnapshot))
            #expect(mutation.status == .blocked && mutation.diagnostics.contains { $0.code.rawValue == "unsupported_request_schema" })
        }
    }

    @Test func legacyRequestExecutesWithoutChangingOutputSchemas() async throws {
        var request = PhysicalDesignFixtureFactory.request(stage: .floorplan,
            snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false, includeRoutes: false, includeVias: false))
        request.schemaVersion = 7
        let store = InMemoryPhysicalDesignArtifactStore(), codec = PhysicalDesignJSONCodec()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        #expect(result.schemaVersion == PhysicalDesignResult.currentSchemaVersion && result.schemaVersion == 7)
        let manifest = try #require(result.payload.runManifest)
        let decoded = try codec.decode(PhysicalDesignRunManifest.self, from: await store.read(manifest))
        #expect(decoded.schemaVersion == 7 && decoded.implementationConfiguration == request.configuration)
        let output = try #require(result.payload.physicalDesign)
        let snapshot = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(output.layoutArtifact))
        #expect(snapshot.schemaVersion == 2)
    }

    @Test func sourceFreeOptInRefusesAtomically() async throws {
        var request = PhysicalDesignFixtureFactory.request(stage: .floorplan,
            snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false, includeRoutes: false, includeVias: false))
        var constraints = request.configuration.implementationConstraints ?? .default
        constraints.sourceRoutingWidthPolicy = .sourceDefault
        request.configuration.implementationConstraints = constraints
        let store = InMemoryPhysicalDesignArtifactStore()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.runManifest == nil)
        #expect(result.diagnostics.contains { $0.code.rawValue == "physical_technology_unsupported" && $0.summary.contains("Source-default width") }, "\(result.diagnostics)")
        #expect(await store.data(at: "runs/\(request.runID)/physical-design/floorplan/revision.json") == nil)
        let mutation = await PhysicalDesignNativeMutationEngine().apply(request, to: try #require(request.initialSnapshot))
        #expect(mutation.status == .blocked && mutation.snapshot == nil)
        #expect(mutation.diagnostics.contains { $0.code.rawValue == "source_routing_width_policy_unsupported" })
        // The nonoptional numeric field keeps its structural contract even in source-default mode.
        constraints.routeWidth = 0
        #expect(!constraints.validationDiagnostics().isEmpty)
    }

    @Test func characterizedCTSRetainsSourceSpacingFloor() async throws {
        var (request, store, _, _) = try await CharacterizedNativeCTSTests().fixture(buffered: false)
        var constraints = request.configuration.implementationConstraints ?? .default
        constraints.sourceRoutingWidthPolicy = .sourceDefault
        constraints.routeSpacing = 50
        request.configuration.implementationConstraints = constraints
        let snapshot = try #require(request.initialSnapshot)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: snapshot.unitsPerMicron)
        let prepared = try PhysicalDesignTechnologyConstraints.prepare(snapshot, request: request,
            processInputs: inputs, processGeometry: geometry)
        #expect(prepared.implementationState?.tracks == snapshot.implementationState?.tracks)
        for layer in request.configuration.preferredRoutingLayers {
            let source = try geometry.routingWidthAndSpacing(layer: layer, units: snapshot.unitsPerMicron, width: nil)
            #expect(source.spacing == 100 && source.spacing > constraints.routeSpacing)
        }
        // Without source characterization, CTS cannot opt into the router-owned spacing profile.
        request.clockTimingModel = nil
        do {
            _ = try PhysicalDesignTechnologyConstraints.prepare(snapshot, request: request,
                processInputs: inputs, processGeometry: geometry)
            Issue.record("Uncharacterized CTS must retain its spacing preparation refusal.")
        } catch let error as PhysicalDesignTechnologyError {
            guard case .invalid(let message) = error else { throw error }
            #expect(message.contains("Configured spacing is below LEF constraints"))
        }
    }

    @Test func sourceGeometryOwnsDefaultWidth() async throws {
        let (geometry, _, _) = try await ProcessGeometryTests().fixture()
        for layer in [2, 3] {
            let derived = try geometry.routingWidthAndSpacing(layer: layer, units: 1000, width: nil)
            #expect(derived.width == 100 && derived.spacing == 100)
            let uniform = try geometry.routingWidthAndSpacing(layer: layer, units: 1000, width: 100)
            #expect(uniform.width == derived.width && uniform.spacing == derived.spacing)
            #expect(throws: PhysicalDesignRoutingSourceError.self) {
                try geometry.routingWidthAndSpacing(layer: layer, units: 1000, width: 170)
            }
        }
    }
}
