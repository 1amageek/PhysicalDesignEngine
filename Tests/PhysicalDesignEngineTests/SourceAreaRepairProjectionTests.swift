import MaskGeometry
import Testing
@testable import PhysicalDesignCore

@Suite("Read-only retained source AREA projection", .timeLimit(.minutes(1)))
struct SourceAreaRepairProjectionTests {
    @Test("projection observes both deficient and sufficient retained material without an AREA verdict", arguments: [100, 1000])
    func retainedAreaObservation(_ length: Int) async throws {
        let (geometry, request, _) = try await ProcessGeometryTests().fixture(minimumArea: "0.03")
        let snapshot = try geometry.bind(self.snapshot(length: Int64(length)))
        let profile = self.profile(request)
        #expect(geometry.sourceLayers[2]?.area == 0.03)
        let threshold = try #require(geometry.routingMinimumAreas[2])
        #expect(threshold.minimumDBU2 == 30_000)
        let projection = try PhysicalDesignRepairProjection(snapshot: snapshot, geometry: geometry,
            profile: profile, limits: limits(), requireGateFacts: false)
        #expect(projection.snapshot == snapshot && projection.rectangles.count == 1)
        let record = try #require(projection.rectangles.first)
        let segment = try #require(snapshot.routes.first?.segments.first)
        let footprint = try segment.qualifiedFootprint()
        #expect(projection.integerBounds[record.id] == footprint)
        #expect(projection.sourceIDByRecordID[record.id] == "route:retained:wire")
        #expect(record.layer == "metH" && record.netID == "N")
        #expect(record.xMin == 0.95 && record.yMin == 0.95 && record.yMax == 1.05)
        let polygons = try PhysicalDesignSourceRouter.rectangle(footprint, layer: 2)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let components = try PhysicalDesignRoutingAreaGeometry.compile(polygons, budget: &budget)
        let actual = try #require(components.first)
        #expect(components.count == 1 && actual.areaDBU2 == UInt64((length + 100) * 100))
        #expect(threshold.accepts(actual.areaDBU2) == (length == 1000))
    }

    @Test("observational projection still refuses missing and wrong source widths", arguments: ["missing", "wrong"])
    func widthRefusal(_ failure: String) async throws {
        let (geometry, request, _) = try await ProcessGeometryTests().fixture(minimumArea: "0.03")
        var input = snapshot(length: 1000)
        input.routes[0].segments[0].widthDBU = failure == "missing" ? nil : 120
        let bound = try geometry.bind(input)
        if failure == "wrong" {
            #expect(throws: PhysicalDesignRoutingSourceError.self) {
                try PhysicalDesignRepairProjection(snapshot: bound, geometry: geometry,
                    profile: profile(request), limits: limits(), requireGateFacts: false)
            }
        } else {
            #expect(throws: PhysicalDesignTechnologyError.self) {
                try PhysicalDesignRepairProjection(snapshot: bound, geometry: geometry,
                    profile: profile(request), limits: limits(), requireGateFacts: false)
            }
        }
    }

    @Test("read-only observation does not unlock an AREA constructor or unsupported stage")
    func constructorAndStageRemainRefused() async throws {
        let (geometry, base, _) = try await ProcessGeometryTests().fixture(minimumArea: "0.03")
        let input = try geometry.bind(snapshot(length: 1000))
        _ = try PhysicalDesignRepairProjection(snapshot: input, geometry: geometry,
            profile: profile(base), limits: limits(), requireGateFacts: false)
        #expect(throws: PhysicalDesignRoutingSourceError.self) {
            try geometry.routingWidthAndSpacing(layer: 2, units: 1000, width: 100)
        }
        var request = base; request.stage = .antennaRepair
        #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.validateAreaStage(request, snapshot: input) }
    }

    private func snapshot(length: Int64) -> PhysicalDesignSnapshot {
        var snapshot = PhysicalDesignSnapshot(topCell: "area_observation", unitsPerMicron: 1000,
            die: .init(x: 0, y: 0, width: 10_000, height: 10_000), core: .init(x: 0, y: 0, width: 10_000, height: 10_000))
        snapshot.nets = [.init(id: "N", pinIDs: [])]
        snapshot.routes = [.init(id: "retained", netID: "N", segments: [
            .init(id: "wire", layer: 2, x1: 1000, y1: 1000, x2: 1000 + length, y2: 1000,
                widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))])]
        return snapshot
    }

    private func profile(_ request: PhysicalDesignRequest) -> PhysicalDesignRepairMeasurementProfile {
        .init(processManifest: request.pdk.manifest, processAssets: request.processAssets.mapValues(\.reference),
            processLayerOrder: ["metH", "cutHV", "metV"], rules: [])
    }

    private func limits() -> PhysicalDesignRepairMeasurementLimits {
        .init(maximumInputBytes: 1_000_000, maximumProjectionRecords: 1000,
            maximumGeometryProbes: 100_000, maximumBackendWork: 100_000, timeoutSeconds: 5)
    }
}
