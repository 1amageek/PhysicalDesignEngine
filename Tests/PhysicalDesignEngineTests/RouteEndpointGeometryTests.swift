import DEF
import Foundation
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Exact retained route endpoint geometry", .timeLimit(.minutes(1)))
struct RouteEndpointGeometryTests {
    @Test("ordered signed extensions define exact horizontal and vertical footprints", arguments: ["flush", "half", "custom", "reverse", "vertical", "reverse-vertical", "negative"])
    func orderedFootprints(kind: String) throws {
        let vertical = kind.contains("vertical")
        let reversed = kind.hasPrefix("reverse")
        let begin: Int64 = kind == "half" ? 100 : kind == "custom" || reversed ? 25 : kind == "negative" ? -25 : 0
        let end: Int64 = kind == "half" ? 100 : kind == "custom" || reversed ? 75 : kind == "negative" ? -50 : 0
        let first: Int64 = reversed ? 900 : 100, last: Int64 = reversed ? 100 : 900
        let segment = PhysicalDesignSnapshot.RouteSegment(id: "wire", layer: 2,
            x1: vertical ? 500 : first, y1: vertical ? first : 500,
            x2: vertical ? 500 : last, y2: vertical ? last : 500, widthDBU: 200,
            endpointExtensions: .init(beginDBU: begin, endDBU: end))
        let lower: Int64 = reversed ? 25 : 100 - begin
        let span: Int64 = 800 + begin + end
        #expect(try segment.qualifiedFootprint() == (vertical
            ? .init(x: 400, y: lower, width: 200, height: span)
            : .init(x: lower, y: 400, width: span, height: 200)))
        #expect(segment.x1 == (vertical ? 500 : first) && segment.y2 == (vertical ? last : 500))
    }

    @Test("invalid footprint qualification rejects without arithmetic traps", arguments: ["missing", "width", "odd", "zero", "diagonal", "overflow", "collapsed", "begin-retraction", "end-retraction"])
    func invalidFootprints(kind: String) {
        var segment = PhysicalDesignSnapshot.RouteSegment(id: "wire", layer: 2, x1: 100, y1: 500, x2: 900, y2: 500,
            widthDBU: 200, endpointExtensions: .init(beginDBU: 0, endDBU: 0))
        switch kind {
        case "missing": segment.endpointExtensions = nil
        case "width": segment.widthDBU = nil
        case "odd": segment.widthDBU = 201
        case "zero": segment.x2 = segment.x1
        case "diagonal": segment.y2 += 1
        case "overflow": segment.endpointExtensions = .init(beginDBU: .min, endDBU: 0)
        case "begin-retraction": segment.endpointExtensions = .init(beginDBU: -2000, endDBU: 3000)
        case "end-retraction": segment.endpointExtensions = .init(beginDBU: 3000, endDBU: -2000)
        default: segment.endpointExtensions = .init(beginDBU: -500, endDBU: -500)
        }
        #expect(throws: PhysicalDesignRouteEndpointExtensions.GeometryError.self) { try segment.qualifiedFootprint() }
    }

    @Test("public native producer retains special flush routes and declared status/use/shape", arguments: [DEFRouteWire.RouteStatus.routed, .fixed, .cover])
    func originalSpecialProducer(status: DEFRouteWire.RouteStatus) async throws {
        let (geometry, base, store) = try await ProcessGeometryTests().fixture()
        var request = ProcessGeometryTests().nativeRequest(base)
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        let use: DEFSpecialNet.NetUse? = status == .cover ? .ground : nil
        let shape: DEFRouteSegment.RouteShape? = status == .fixed ? .stripe : nil
        snapshot.nets = ["in", "out", "vdd", "vss"].map { .init(id: $0, pinIDs: [], routingClass: .special, defUse: use) }
        snapshot.routes = snapshot.nets.enumerated().map { index, net in
            .init(id: net.id, netID: net.id, segments: [.init(id: "wire-" + net.id, layer: 2,
                x1: Int64(1000 + index * 500), y1: Int64(500 + index * 500), x2: net.id == "out" ? 9000 : 0,
                y2: Int64(500 + index * 500), widthDBU: 200, endpointExtensions: .init(beginDBU: 0, endDBU: 0))], defStatus: status, defShape: shape)
        }
        request.initialSnapshot = snapshot
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let physical = try #require(result.payload.physicalDesign)
        let retained = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(physical.layoutArtifact))
        #expect(retained.nets == snapshot.nets && retained.routes == snapshot.routes)
        let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        let producer = try await store.read(def)
        #expect(try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: retained, request: request,
            artifactStore: store, limits: .init(maximumInputByteCount: 1_000_000, maximumGeometryRecordCount: 100_000,
                maximumOutputByteCount: 1_000_000)) == producer)
        let document = try DEFLibraryReader.read(producer)
        #expect(document.nets.isEmpty && document.specialNets.count == 4)
        for net in document.specialNets {
            let segment = try #require(snapshot.routes.first { $0.netID == net.name }?.segments.first)
            let route = try #require(net.routing.first)
            #expect(net.use == use && route.status.rawValue == status.rawValue && route.width == 200 && route.shape == shape)
            #expect(route.points == [.init(x: Int32(segment.x1), y: Int32(segment.y1), ext: 0),
                                     .init(x: Int32(segment.x2), y: Int32(segment.y2), ext: 0)])
        }
    }

    @Test("unsupported route meaning and negative DEF caps cannot publish", arguments: ["class", "status", "new", "noshield", "shape", "negative"])
    func unsupportedExport(kind: String) async throws {
        let (geometry, base, store) = try await ProcessGeometryTests().fixture()
        var request = ProcessGeometryTests().nativeRequest(base)
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        snapshot.nets = [.init(id: "N", pinIDs: [])]
        snapshot.routes = [.init(id: "route", netID: "N", segments: [.init(id: "wire", layer: 2,
            x1: 100, y1: 100, x2: 900, y2: 100, widthDBU: 100, endpointExtensions: .init(beginDBU: 50, endDBU: 50))])]
        switch kind {
        case "class": snapshot.nets[0].routingClass = nil
        case "status": snapshot.routes[0].defStatus = nil
        case "new": snapshot.routes[0].defStatus = .new_
        case "noshield": snapshot.routes[0].defStatus = .noshield
        case "shape": snapshot.routes[0].defShape = .stripe
        default: snapshot.routes[0].segments[0].endpointExtensions = .init(beginDBU: -25, endDBU: 0)
        }
        request.initialSnapshot = snapshot
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil)
        #expect(result.diagnostics.contains { $0.code.rawValue == "physical_def_export_unsupported" })
    }

    @Test("public source-bound export refuses width-only unqualified caps")
    func unqualifiedPublicExport() async throws {
        let (geometry, base, store) = try await ProcessGeometryTests().fixture()
        let request = ProcessGeometryTests().nativeRequest(base)
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        snapshot.nets = [.init(id: "N", pinIDs: [])]
        snapshot.routes = [.init(id: "route", netID: "N", segments: [
            .init(id: "wire", layer: 2, x1: 100, y1: 100, x2: 900, y2: 100, widthDBU: 100)
        ])]
        await #expect(throws: PhysicalDesignStandardLayoutExportError.self) {
            try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request,
                artifactStore: store, limits: .init(maximumInputByteCount: 1_000_000, maximumGeometryRecordCount: 100_000,
                    maximumOutputByteCount: 1_000_000))
        }
    }
}
