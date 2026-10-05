import DEF
import Foundation
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Exact native top-port interchange", .timeLimit(.minutes(1)))
struct TopPortInterchangeTests {
    @Test("native producer and public exporter retain four real top ports")
    func nativeTopPortProducerPairing() async throws {
        let (_, base, store) = try await ProcessGeometryTests().fixture()
        var request = ProcessGeometryTests().nativeRequest(base)
        request.runID = "top-port-source"
        request.initialSnapshot = nil
        let input = try await store.registerInput(Data(source().utf8), relativePath: "inputs/top-ports.def", kind: .layout, format: .def)
        request.inputLayout = .init(layoutArtifact: input, topCell: "fixture_top", layoutDigest: input.reference.digest.hexadecimalValue)
        request.inputs.append(input.reference)
        request.inputBindings.append(input)
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let layout = try #require(result.payload.physicalDesign?.layoutArtifact)
        let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(layout))
        #expect(snapshot.pins.filter { $0.cellID == nil }.map(\.name).sorted() == ["in", "out", "vdd", "vss"])
        #expect(snapshot.pins.contains { $0.cellID == "U1" && $0.name == "Y" })
        let producer = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        let bytes = try await store.read(producer)
        let exported = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request,
            artifactStore: store, limits: .init(maximumInputByteCount: 1_000_000, maximumGeometryRecordCount: 100_000, maximumOutputByteCount: 1_000_000))
        #expect(exported == bytes)
        let standard = try DEFLibraryReader.read(exported)
        #expect(standard.pins.count == 4)
        #expect(standard.pins.allSatisfy { $0.layerRects.count == 1 && $0.layerRects[0].rects.count == 1 })
        #expect(standard.pins.map(\.name).sorted() == ["in", "out", "vdd", "vss"])
        #expect(standard.pins.first { $0.name == "vdd" }?.use == .power)
        #expect(standard.pins.first { $0.name == "vss" }?.use == .ground)
        request.runID = "top-port-reimport"
        request.inputLayout = .init(layoutArtifact: producer, topCell: snapshot.topCell, layoutDigest: producer.reference.digest.hexadecimalValue)
        request.inputs.append(producer.reference); request.inputBindings.append(producer)
        let reimported = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(reimported.status == .completed, "\(reimported.diagnostics)")
        let roundTrip = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
            from: await store.read(#require(reimported.payload.physicalDesign?.layoutArtifact)))
        #expect(roundTrip.pins.filter { $0.cellID == nil } == snapshot.pins.filter { $0.cellID == nil })
    }

    @Test("real source TOP-to-cell routing retains port authority")
    func nativeTopPortRouting() async throws {
        let (request, store, port) = try await routedFixture()
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let reference = try #require(result.payload.physicalDesign)
        let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
        let top = try #require(snapshot.pins.first { $0.cellID == nil })
        #expect(top.topPort == port && top.netID == "N" && top.direction == "input")
        #expect(!snapshot.routes.isEmpty)
        for pin in snapshot.pins {
            #expect(snapshot.routes.flatMap(\.segments).contains {
                $0.layer == pin.accessLayer && (($0.x1 == pin.x && $0.y1 == pin.y) || ($0.x2 == pin.x && $0.y2 == pin.y))
            })
        }
        let output = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        let def = try DEFLibraryReader.read(await store.read(output))
        let actual = try #require(def.pins.first)
        #expect(actual.name == "IN" && actual.netName == "N" && actual.direction == .input)
        #expect(actual.x == port.placementX && actual.y == port.placementY && actual.orientation == port.orientation)
        #expect(actual.layerRects[0].rects[0] == .init(x1: -300, y1: -300, x2: 300, y2: 300))
    }

    @Test("all source poses and odd DBU rectangles remain exact", arguments: DEFOrientation.allCases)
    func sourcePoses(orientation: DEFOrientation) async throws {
        let (_, request, store) = try await ProcessGeometryTests().fixture()
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let source = source().replacingOccurrences(of: "( -50 -100 ) ( 150 100 )", with: "( 10 20 ) ( 111 221 )")
            .replacingOccurrences(of: ") N ;", with: ") \(orientation.rawValue) ;")
        let decoded = PhysicalDesignDEFParser().parseResolved(Data(source.utf8), processFactory: { units in
            try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: units)
        })
        #expect(decoded.result.isValid, "\(decoded.result.diagnostics)")
        let pin = try #require(decoded.result.snapshot?.pins.first { $0.name == "in" })
        let port = try #require(pin.topPort)
        #expect(port.orientation == orientation && port.placementX == 1000 && port.placementY == 5000)
        let expected: [DEFOrientation: PhysicalDesignSnapshot.Rect] = [
            .n: .init(x: 1010, y: 5020, width: 101, height: 201), .s: .init(x: 889, y: 4779, width: 101, height: 201),
            .e: .init(x: 1020, y: 4889, width: 201, height: 101), .w: .init(x: 779, y: 5010, width: 201, height: 101),
            .fn: .init(x: 889, y: 5020, width: 101, height: 201), .fs: .init(x: 1010, y: 4779, width: 101, height: 201),
            .fe: .init(x: 779, y: 4889, width: 201, height: 101), .fw: .init(x: 1020, y: 5010, width: 201, height: 101)
        ]
        #expect(try port.worldRectangle() == expected[orientation])
        #expect(pin.x == expected[orientation]?.x && pin.y == expected[orientation]?.y)
        let encoded = try PhysicalDesignJSONCodec().encode(#require(decoded.result.snapshot))
        #expect(try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: encoded) == decoded.result.snapshot)
        let exported = try PhysicalDesignDEFWriter().write(#require(decoded.result.snapshot), processGeometry: #require(decoded.geometry))
        let actual = try #require(DEFLibraryReader.read(Data(exported.utf8)).pins.first { $0.name == "in" })
        #expect(actual.x == 1000 && actual.y == 5000 && actual.orientation == orientation)
        #expect(actual.layerRects[0].rects[0] == .init(x1: 10, y1: 20, x2: 111, y2: 221))
    }

    @Test("unsupported source geometry and contradictory port semantics reject atomically", arguments:
          ["missing-use", "missing-direction", "missing-layer", "duplicate-layer", "mask", "polygon", "zero", "overflow", "net", "unplaced"])
    func rejectsTopPortSource(scenario: String) async throws {
        let (_, request, store) = try await ProcessGeometryTests().fixture()
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        var text = source()
        switch scenario {
        case "missing-use": text = text.replacingOccurrences(of: " + USE SIGNAL", with: "")
        case "missing-direction": text = text.replacingOccurrences(of: " + DIRECTION INPUT", with: "")
        case "missing-layer": text = text.replacingOccurrences(of: " + LAYER metH ( -50 -100 ) ( 150 100 )", with: "")
        case "duplicate-layer": text = text.replacingOccurrences(of: " + LAYER metH", with: " + LAYER metH ( -50 -100 ) ( 150 100 ) + LAYER metH")
        case "mask": text = text.replacingOccurrences(of: " + LAYER metH", with: " + LAYER metH MASK 1")
        case "polygon": text = text.replacingOccurrences(of: " + LAYER metH", with: " + POLYGON metH")
        case "zero": text = text.replacingOccurrences(of: "( 150 100 )", with: "( -50 100 )")
        case "overflow": text = text.replacingOccurrences(of: "( 1000 5000 ) N", with: "( 2147483647 5000 ) N")
        case "net": text = text.replacingOccurrences(of: "- out ( PIN out )", with: "- out ( PIN in )")
        case "unplaced": text = text.replacingOccurrences(of: "+ FIXED ( 1000 5000 ) N", with: "+ UNPLACED")
        default: Issue.record("Unknown top-port counterexample")
        }
        let parsed = PhysicalDesignDEFParser().parseResolved(Data(text.utf8), processFactory: { units in
            try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: units)
        })
        #expect(!parsed.result.isValid && parsed.result.snapshot == nil)
        #expect(parsed.result.diagnostics.contains { $0.severity == .error && $0.code.hasPrefix("def_process_top") })
    }

    @Test("missing geometry and obstructed exact TOP access do not publish candidates", arguments: ["missing", "obstructed"])
    func refusesInvalidTopRouting(scenario: String) async throws {
        var (request, store, _) = try await routedFixture()
        if scenario == "missing" { request.initialSnapshot?.pins[1].topPort = nil }
        else { request.initialSnapshot?.blockages = [.init(x: 3900, y: 1000, width: 800, height: 800)] }
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.payload.physicalDesign == nil)
        #expect(!result.diagnostics.isEmpty)
        if scenario == "obstructed" { #expect(result.diagnostics.contains { $0.code.rawValue == "routing_pin_access_unavailable" }) }
    }

    private func routedFixture() async throws -> (PhysicalDesignRequest, InMemoryPhysicalDesignArtifactStore, PhysicalDesignTopPort) {
        let (_, base, store) = try await ProcessGeometryTests().fixture(routingPorts: true)
        var request = ProcessGeometryTests().nativeRequest(base)
        request.runID = "top-source-routing"; request.stage = .globalRouting
        let port = PhysicalDesignTopPort(rectangle: .init(x: -300, y: -300, width: 600, height: 600), layer: 2,
            placementX: 4300, placementY: 1400, orientation: .n, placementStatus: .fixed, use: .signal)
        request.initialSnapshot = .init(topCell: base.design.topDesignName, die: .init(x: 0, y: 0, width: 10000, height: 10000),
            core: .init(x: 0, y: 0, width: 10000, height: 10000),
            rows: [.init(id: "row", originX: 0, originY: 1000, siteWidth: 100, height: 1000, siteCount: 100, siteName: "unit")],
            cells: [.init(id: "U1", master: "INV_X1", x: 500, y: 1000, width: 2000, height: 1000, placed: true)],
            pins: [.init(id: "U1/Y", cellID: "U1", name: "Y", x: 1900, y: 1300, netID: "N", direction: "output", accessLayer: 2),
                   .init(id: "TOP/IN", name: "IN", x: 4300, y: 1400, netID: "N", direction: "input", accessLayer: 2, topPort: port)],
            nets: [.init(id: "N", pinIDs: ["U1/Y", "TOP/IN"])],
            implementationState: .init(tracks: [.init(id: "H", layer: 2, direction: "horizontal", origin: 100, spacing: 200, count: 50),
                                              .init(id: "V", layer: 3, direction: "vertical", origin: 100, spacing: 400, count: 25)]))
        return (request, store, port)
    }

    private func source() -> String {
        var text = "VERSION 5.8 ;\nDESIGN fixture_top ;\nUNITS DISTANCE MICRONS 1000 ;\nDIEAREA ( 0 0 ) ( 10000 10000 ) ;\nROW row unit 0 3000 N DO 100 BY 1 STEP 100 0 ;\nCOMPONENTS 1 ;\n- U1 INV_X1 + FIXED ( 2000 3000 ) FN ;\nEND COMPONENTS\nPINS 4 ;\n"
        for (index, name) in ["in", "out", "vdd", "vss"].enumerated() {
            let use = name == "vdd" ? "POWER" : name == "vss" ? "GROUND" : "SIGNAL"
            let direction = name == "in" ? "INPUT" : name == "out" ? "OUTPUT" : "INOUT"
            text += "- \(name) + NET \(name) + DIRECTION \(direction) + USE \(use) + LAYER metH ( -50 -100 ) ( 150 100 ) + FIXED ( \(1000 + index * 1000) 5000 ) N ;\n"
        }
        return text + "END PINS\nNETS 4 ;\n- in ( PIN in ) ;\n- out ( PIN out ) ( U1 Y ) ;\n- vdd ( PIN vdd ) ;\n- vss ( PIN vss ) ;\nEND NETS\nEND DESIGN\n"
    }
}
