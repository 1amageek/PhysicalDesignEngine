import Foundation
import LayoutIR
import PDKCore
import Testing
@testable import PhysicalDesignCore

@Suite("Borrowed exact routing contact pairs", .timeLimit(.minutes(1)))
struct RoutingCutPairTests {
    @Test("actual edge spacing is inclusive at the exact source threshold", arguments: [49, 50, 99, 100, 101])
    func edgeSpacing(_ offset: Int) async throws {
        let geometry = try await fixture()
        let first = contact("first"), second = contact("second", x: 1000 + Int64(offset))
        let a = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        let b = try geometry.viaShapes(master: "hv", x: second.x, y: second.y)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        let fits = try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: b, budget: &budget)
        #expect(fits == (offset >= 100))
        if fits { try geometry.validateRoutingCuts([first, second]) }
        else { #expect(throws: PhysicalDesignTechnologyError.self) { try geometry.validateRoutingCuts([first, second]) } }
    }

    @Test("every cut primitive participates in the pair law", arguments: [199, 200])
    func multipleCutPrimitives(_ offset: Int) async throws {
        let geometry = try await fixture(multipleCuts: true)
        let first = contact("first"), second = contact("second", x: 1000 + Int64(offset))
        let a = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        let b = try geometry.viaShapes(master: "hv", x: second.x, y: second.y)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: b, budget: &budget) == (offset == 200))
    }

    @Test("physical reuse ignores record ID and redundancy but never net or master")
    func reuseIdentity() async throws {
        let geometry = try await fixture()
        let first = contact("first")
        let a = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        var reused = first; reused.id = "another-record"; reused.isRedundant = true
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try geometry.routingCutPairFits(first, shapes: a, against: reused, otherShapes: a, budget: &budget))
        var foreign = reused; foreign.netID = "foreign"
        #expect(try !geometry.routingCutPairFits(first, shapes: a, against: foreign, otherShapes: a, budget: &budget))
        var alternate = reused; alternate.master = "alias"
        let b = try geometry.viaShapes(master: "alias", x: alternate.x, y: alternate.y)
        #expect(try !geometry.routingCutPairFits(first, shapes: a, against: alternate, otherShapes: b, budget: &budget))
    }

    @Test("declared identity and cut inventory are checked before reuse", arguments: ["master", "layers", "candidate-cuts", "prior-cuts", "vertices"])
    func invalidBeforeReuse(_ failure: String) async throws {
        let geometry = try await fixture()
        var first = contact("first"), second = contact("second")
        var a = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        var b = a
        switch failure {
        case "master": first.master = "missing"; second.master = "missing"
        case "layers": first.upperLayer = 2; second.upperLayer = 2
        case "candidate-cuts": a.removeAll { $0.layer == 4 }
        case "prior-cuts": b.removeAll { $0.layer == 4 }
        default:
            let index = try #require(a.firstIndex { $0.layer == 4 })
            a[index].points.removeAll()
        }
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: b, budget: &budget)
        }
    }

    @Test("different declared cut layers are separate only with both cut inventories")
    func distinctCutLayers() async throws {
        let (_, _, geometry) = try await NativeRepairMeasurementTests().fixture(antenna: .reroute)
        let first = contact("first")
        let second = PhysicalDesignSnapshot.Via(id: "upper", netID: "N", x: 1000, y: 1000,
            lowerLayer: 3, upperLayer: 5, master: "vu")
        let a = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        let b = try geometry.viaShapes(master: "vu", x: second.x, y: second.y)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: b, budget: &budget))
        let missing = b.filter { $0.layer != geometry.vias["vu"]?.cutLayer }
        #expect(throws: PhysicalDesignTechnologyError.self) {
            try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: missing, budget: &budget)
        }
    }

    @Test("the same caller allowance covers repeated pair checks")
    func cumulativeQuota() async throws {
        let geometry = try await fixture(), first = contact("first"), second = contact("second", x: 1100)
        let a = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        let b = try geometry.viaShapes(master: "hv", x: second.x, y: second.y)
        var measured = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: b, budget: &measured))
        let onePair = measured.checks
        #expect(onePair > 0)
        var exact = PhysicalDesignRoutingWorkBudget(caller: onePair)
        #expect(try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: b, budget: &exact))
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: b, budget: &exact)
        }
        var below = PhysicalDesignRoutingWorkBudget(caller: onePair - 1)
        #expect(throws: PhysicalDesignSourceRouter.Failure.self) {
            try geometry.routingCutPairFits(first, shapes: a, against: second, otherShapes: b, budget: &below)
        }
        #expect(exact.checks == onePair && below.checks <= onePair - 1)
    }

    @Test("cancellation is checked even for identical physical contact reuse")
    func cancellation() async throws {
        let geometry = try await fixture(), first = contact("first")
        let shapes = try geometry.viaShapes(master: "hv", x: first.x, y: first.y)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
            do {
                _ = try geometry.routingCutPairFits(first, shapes: shapes, against: first, otherShapes: shapes, budget: &budget)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        #expect(await task.value)
    }

    private func contact(_ id: String, x: Int64 = 1000) -> PhysicalDesignSnapshot.Via {
        .init(id: id, netID: "N", x: x, y: 1000, lowerLayer: 2, upperLayer: 3, master: "hv")
    }

    private func fixture(multipleCuts: Bool = false) async throws -> PhysicalDesignProcessGeometry {
        var (request, store) = try await ProcessGeometryTests().fixtureSources()
        let original = try #require(request.processAssets["tech"])
        var text = try #require(String(data: await store.read(original), encoding: .utf8))
        if multipleCuts {
            text = text.replacingOccurrences(of: "RECT -0.1 -0.1 0.1 0.1 ;", with: "RECT -0.2 -0.2 0.2 0.2 ;")
            text = text.replacingOccurrences(of: "RECT -0.025 -0.025 0.025 0.025 ;",
                with: "RECT -0.025 -0.025 0.025 0.025 ; RECT 0.075 -0.025 0.125 0.025 ;")
        }
        let begin = try #require(text.range(of: "VIA hv DEFAULT")), end = try #require(text.range(of: "END hv"))
        let alias = String(text[begin.lowerBound..<end.upperBound]).replacingOccurrences(of: "hv", with: "alias")
        let bytes = Data(text.replacingOccurrences(of: "END LIBRARY", with: alias + "\nEND LIBRARY").utf8)
        let source = try await store.registerInput(bytes, relativePath: "inputs/pair-vias.lef", kind: .technology, format: .lef)
        var manifest = try PDKManifestCodec.decode(data: await store.read(request.requireBinding(for: request.pdk.manifest)))
        let index = try #require(manifest.assets.firstIndex { $0.assetID == "tech" })
        manifest.assets[index].path = source.path
        manifest.assets[index].sha256 = source.reference.digest.hexadecimalValue
        manifest.assets[index].byteCount = Int64(bytes.count)
        let binding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/pair-process.json", kind: .technology, format: .json)
        let previousManifest = request.pdk.manifest
        request.inputBindings.removeAll { $0.reference == previousManifest || $0 == original }
        request.pdk = try .init(manifest: binding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: binding),
            processID: request.pdk.processID, version: request.pdk.version)
        request.processAssets["tech"] = source
        request.inputBindings.append(contentsOf: [binding, source])
        request.inputs = request.inputBindings.map(\.reference)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        return try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
    }
}
