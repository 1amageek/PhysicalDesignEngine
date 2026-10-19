import Foundation
import LEF
import PDKCore
import Testing
import TimingCore
@testable import PhysicalDesignCore

@Suite("Source-bound placement terminal classification", .timeLimit(.minutes(1)))
struct PlacementTerminalClassificationTests {
    typealias Classification = NativePhysicalDesignPlacementTerminalClassification

    @Test("Explicit supply is separated while signal identity and source-only supply remain exact")
    func supplyInventory() async throws {
        var fixture = try await fixture()
        let original = fixture.graph
        let sourceOnly = try fixture.classify()
        #expect(sourceOnly.signalGraph == original)
        #expect(sourceOnly.terminals.filter { $0.coverage == .sourceOnlySupply }.count == 2)
        #expect(sourceOnly.terminals.contains { $0.pinName == "PWR" && $0.role == .power && $0.netID == nil })
        #expect(sourceOnly.terminals.contains { $0.pinName == "GND" && $0.role == .ground && $0.netID == nil })
        fixture.connectSupply()
        let bound = try fixture.classify()
        #expect(bound.signalGraph == original)
        #expect(bound.terminals.contains { $0.physicalPinID == "U/PWR" && $0.netID == "rail" && $0.coverage == .boundSupply })
        #expect(bound.constants.isEmpty && bound.sequentialBindings.isEmpty)
        let records = try PhysicalDesignJSONCodec().decode([Classification.TerminalBinding].self,
            from: PhysicalDesignJSONCodec().encode(bound.terminals))
        #expect(records == bound.terminals)
        let signal = try #require(records.first { $0.pinName == "A" })
        #expect(signal.lefAssetID == "cells" && signal.libertyCellOffset == fixture.source.cells[0].byteOffset)
        #expect(signal.libertyPinOffset == fixture.source.cells[0].pins.first { $0.name == "A" }?.byteOffset)
        // A supply may be present physically without an invented logical connection.
        fixture.graph = original
        #expect(try fixture.classify().signalGraph == original)
    }

    @Test("Names do not classify supply and source CLOCK/RESET remain signals")
    func namesAndControls() async throws {
        var fixture = try await fixture(kind: "ff")
        fixture.graph.nets[0].name = "VDD"
        fixture.graph.instances[0].connections["A"] = "VDD"
        fixture.snapshot.nets[0].id = "VDD"
        fixture.snapshot.pins[0].netID = "VDD"
        let clock = try #require(fixture.snapshot.nets.firstIndex { $0.id == "CLK" })
        fixture.snapshot.nets[clock].isClock = true; fixture.snapshot.nets[clock].defUse = .clock
        let reset = try #require(fixture.snapshot.nets.firstIndex { $0.id == "R" })
        fixture.snapshot.nets[reset].defUse = .reset
        let classified = try fixture.classify()
        #expect(classified.signalGraph == fixture.graph)
        #expect(classified.terminals.contains { $0.netID == "VDD" && $0.role == .signal })
        #expect(classified.terminals.contains { $0.pinName == "CLK" && $0.role == .signal })
        #expect(classified.terminals.contains { $0.pinName == "R" && $0.role == .signal })
        #expect(classified.sequentialBindings.count == 1)
    }

    @Test("Exact top signal ports remain in order while explicit top supply is separately bound")
    func topPorts() async throws {
        var fixture = try await fixture()
        fixture.snapshot.pins.append(.init(id: "input-port", name: "input-port", netID: "A", direction: "input",
            topPort: .init(rectangle: .init(x: 0, y: 0, width: 100, height: 100), layer: 2,
                placementX: 0, placementY: 0, orientation: .n, placementStatus: .fixed, use: .signal)))
        fixture.snapshot.nets[0].pinIDs.append("input-port")
        fixture.graph.ports.append(.init(name: "input-port", direction: .input, net: "A"))
        let signal = fixture.graph
        fixture.connectSupply()
        fixture.snapshot.pins.append(.init(id: "supply-port", name: "supply-port", netID: "rail", direction: "inout",
            topPort: .init(rectangle: .init(x: 0, y: 0, width: 100, height: 100), layer: 2,
                placementX: 0, placementY: 0, orientation: .n, placementStatus: .fixed, use: .power)))
        fixture.snapshot.nets[2].pinIDs.append("supply-port")
        fixture.graph.ports.append(.init(name: "supply-port", direction: .bidirectional, net: "rail"))
        let classified = try fixture.classify()
        #expect(classified.signalGraph == signal)
        #expect(classified.terminals.contains { $0.physicalPinID == "supply-port" && $0.role == .power && $0.coverage == .boundSupply })
        fixture.graph.ports[0].direction = .output
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try fixture.classify() }
    }

    @Test("Constant D does not classify Q as constant, and raw FF/latch references grant no eligibility", arguments: ["ff", "latch"])
    func sequentialConstantData(_ kind: String) async throws {
        var fixture = try await fixture(kind: kind)
        fixture.graph.nets[0].constant = .zero
        let classified = try fixture.classify()
        #expect(classified.signalGraph.nets.first { $0.name == "A" }?.constant == .zero)
        #expect(classified.signalGraph.nets.first { $0.name == "Y" }?.constant == nil)
        #expect(classified.constants.count == 1)
        #expect(classified.constants[0].netID == "A" && classified.constants[0].kind == .logicalLiteral)
        let declaration = try #require(fixture.source.cells[0].sequential.first)
        #expect(classified.sequentialBindings[0].sourceSequentialOffsets == [declaration.byteOffset])
        #expect(classified.sequentialBindings[0].masterName == "INV_X1")
        #expect(declaration.kind == (kind == "ff" ? .flipFlop : .latch))
    }

    @Test("An actual inputless source tie literal is distinct from a supply and a logical literal")
    func literalTie() async throws {
        var fixture = try await fixture(kind: "tie")
        let sourceTie = try fixture.classify()
        #expect(sourceTie.constants.count == 1)
        #expect(sourceTie.constants[0].value == .one && sourceTie.constants[0].kind == .sourceTieOutput)
        #expect(sourceTie.constants[0].driverInstance == "U" && sourceTie.constants[0].driverPin == "Y")
        fixture.graph.nets[0].constant = .one
        #expect(try fixture.classify().constants.count == 2)
        fixture.graph.nets[0].constant = .zero
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try fixture.classify() }
    }

    @Test("Unknown, mixed, contradictory and nonreciprocal required bindings refuse", arguments: [
        "direction", "missing-pin", "missing-net", "incidence", "duplicate-pin", "mixed", "mixed-supplies", "wrong-use", "supply-constant", "unknown-pin", "dynamic-constant", "master", "source"
    ])
    func refuses(_ reason: String) async throws {
        var fixture = try await fixture()
        switch reason {
        case "direction": fixture.snapshot.pins[0].direction = "output"
        case "missing-pin": fixture.snapshot.pins.removeFirst()
        case "missing-net": fixture.graph.nets.removeFirst()
        case "incidence": fixture.snapshot.nets[0].pinIDs = []
        case "duplicate-pin": fixture.snapshot.pins.append(fixture.snapshot.pins[0])
        case "mixed":
            fixture.connectSupply()
            fixture.snapshot.pins[0].netID = "rail"
            fixture.snapshot.nets[2].pinIDs.append("U/A")
            fixture.graph.instances[0].connections["A"] = "rail"
            fixture.snapshot.nets.removeFirst(); fixture.graph.nets.removeFirst()
        case "mixed-supplies":
            fixture.connectSupply()
            fixture.snapshot.pins.append(.init(id: "U/GND", cellID: "U", name: "GND", netID: "rail", direction: "inout"))
            fixture.snapshot.nets[2].pinIDs.append("U/GND")
        case "wrong-use": fixture.snapshot.nets[0].defUse = .power
        case "supply-constant": fixture.connectSupply(); fixture.graph.nets[fixture.graph.nets.count - 1].constant = .one
        case "unknown-pin": fixture.graph.instances[0].connections["A[0]"] = "A"
        case "dynamic-constant": fixture.graph.nets[1].constant = .zero
        case "master": fixture.graph.instances[0].cell = "name-inferred-master"
        default: fixture.snapshot.processAssets = [:]
        }
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try fixture.classify() }
    }

    @Test("Cumulative work/live limits and cancellation fail explicitly and reservations release with the result")
    func resources() async throws {
        let fixture = try await fixture()
        let work = try NativePhysicalDesignPlacementTimingBudget(fixture.limits(work: 1, live: 2_000_000))
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try fixture.classify(budget: work) }
        let live = try NativePhysicalDesignPlacementTimingBudget(fixture.limits(work: 10_000_000, live: 1))
        #expect(throws: PhysicalDesignPlacementTimingError.self) { try fixture.classify(budget: live) }
        let lifecycle = try NativePhysicalDesignPlacementTimingBudget(fixture.limits(work: 10_000_000, live: 2_000_000))
        var retained: Classification? = try fixture.classify(budget: lifecycle)
        #expect(retained?.terminals.isEmpty == false)
        #expect(throws: PhysicalDesignPlacementTimingError.self) {
            _ = try lifecycle.reserveStorage(kind: .liveOwnedBytes, byteCount: 2_000_000)
        }
        retained = nil
        let released = try lifecycle.reserveStorage(kind: .liveOwnedBytes, byteCount: 2_000_000)
        #expect(released.byteCount == 2_000_000)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.classify()
        }
        do { _ = try await task.value; Issue.record("Cancelled classification succeeded") }
        catch is CancellationError { }
    }

    private struct Fixture: Sendable {
        var graph: TimingDesign
        var snapshot: PhysicalDesignSnapshot
        let source: OwnedLibertySource
        let inputs: PhysicalDesignProcessInputs
        let geometry: PhysicalDesignProcessGeometry
        let reference: PhysicalDesignPlacementTimingReference
        func classify(budget: NativePhysicalDesignPlacementTimingBudget? = nil) throws -> Classification {
            try .init(graph: graph, source: source, snapshot: snapshot, inputs: inputs,
                geometry: geometry, budget: budget ?? NativePhysicalDesignPlacementTimingBudget(reference))
        }
        func limits(work: UInt64, live: UInt64) -> PhysicalDesignPlacementTimingReference {
            .init(artifact: reference.artifact, maximumInputBytes: reference.maximumInputBytes, maximumLiveBytes: live,
                maximumWorkUnits: work, maximumPathWorkUnitsPerAnalysis: 1, maximumPathStates: 10,
                maximumEvidenceBytes: reference.maximumEvidenceBytes, timeoutNanoseconds: reference.timeoutNanoseconds)
        }
        mutating func connectSupply() {
            snapshot.pins.append(.init(id: "U/PWR", cellID: "U", name: "PWR", netID: "rail", direction: "inout"))
            snapshot.nets.append(.init(id: "rail", pinIDs: ["U/PWR"], defUse: .power))
            graph.instances[0].connections["PWR"] = "rail"
            graph.nets.append(.init(name: "rail"))
        }
    }

    private func fixture(kind: String = "combinational") async throws -> Fixture {
        var (request, store) = try await ProcessGeometryTests().fixtureSources()
        let old = try #require(request.processAssets["cells"])
        var text = try #require(String(data: await store.read(old), encoding: .utf8))
        var extras = """
        PIN PWR DIRECTION INOUT ; USE POWER ; PORT LAYER metH ; RECT 0.5 0.7 0.8 0.8 ; END END PWR
        PIN GND DIRECTION INOUT ; USE GROUND ; PORT LAYER metH ; RECT 0.5 0.5 0.8 0.6 ; END END GND
        """
        var signalPins = [("A", "input"), ("Y", "output")]
        var sequential = ""
        var libertyPins = "pin(A){direction:input;} pin(Y){direction:output;function:\"!A\";}"
        if kind == "tie" {
            let start = try #require(text.range(of: "  PIN A DIRECTION INPUT"))
            let end = try #require(text.range(of: "  END A", range: start.lowerBound..<text.endIndex))
            text.removeSubrange(start.lowerBound..<end.upperBound)
            signalPins = [("Y", "output")]
            libertyPins = "pin(Y){direction:output;function:\"1\";}"
        } else if kind == "ff" || kind == "latch" {
            extras += "\nPIN CLK DIRECTION INPUT ; USE CLOCK ; PORT LAYER metH ; RECT 0.8 0.1 0.9 0.2 ; END END CLK"
            extras += "\nPIN R DIRECTION INPUT ; USE SIGNAL ; PORT LAYER metH ; RECT 0.8 0.3 0.9 0.4 ; END END R"
            signalPins += [("CLK", "input"), ("R", "input")]
            sequential = kind == "ff" ? "ff(IQ,IQN){clocked_on:\"CLK\";next_state:\"A\";clear:\"!R\";}"
                : "latch(IQ,IQN){enable:\"CLK\";data_in:\"A\";clear:\"!R\";}"
            libertyPins = "pin(A){direction:input;} pin(Y){direction:output;function:\"IQ\";} pin(CLK){direction:input;} pin(R){direction:input;}"
        }
        text = text.replacingOccurrences(of: "END INV_X1", with: extras + "\nEND INV_X1")
        let binding = try await store.registerInput(Data(text.utf8), relativePath: "inputs/classification-cells.lef", kind: .technology, format: .lef)
        var manifest = try PDKManifestCodec.decode(data: await store.read(request.requireBinding(for: request.pdk.manifest)))
        let index = try #require(manifest.assets.firstIndex { $0.assetID == "cells" })
        manifest.assets[index].sha256 = binding.reference.digest.hexadecimalValue
        manifest.assets[index].byteCount = Int64(binding.reference.byteCount)
        let pdk = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/classification-process.json", kind: .technology, format: .json)
        let previousManifest = request.pdk.manifest
        request.processAssets["cells"] = binding
        request.inputBindings.removeAll { $0 == old || $0.reference == previousManifest }
        request.inputBindings += [binding, pdk]
        request.inputs.removeAll { $0 == old.reference || $0 == previousManifest }
        request.inputs += [binding.reference, pdk.reference]
        request.pdk = try .init(manifest: pdk.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: pdk), processID: manifest.processID, version: manifest.version)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        let reference = PhysicalDesignPlacementTimingReference(artifact: pdk, maximumInputBytes: 2_000_000,
            maximumLiveBytes: 20_000_000, maximumWorkUnits: 100_000_000, maximumPathWorkUnitsPerAnalysis: 100_000,
            maximumPathStates: 1000, maximumEvidenceBytes: 2_000_000, timeoutNanoseconds: 20_000_000_000)
        let budget = try NativePhysicalDesignPlacementTimingBudget(reference)
        let bytes = Data("library(L){time_unit:\"1ns\";capacitive_load_unit(1,pf);cell(INV_X1){\(sequential)\(libertyPins)pg_pin(PWR){pg_type:primary_power;}pg_pin(GND){pg_type:primary_ground;}}}".utf8)
        let source = try bytes.withUnsafeBytes { raw in
            try LibertyParser().parseSource(raw.bindMemory(to: UInt8.self).span, limits: .init(maximumNestingDepth: 32), resources: budget)
        }
        var snapshot = PhysicalDesignSnapshot(topCell: "top", unitsPerMicron: 1000,
            cells: [.init(id: "U", master: "INV_X1", width: 2000, height: 1000)],
            pins: signalPins.map { .init(id: "U/" + $0.0, cellID: "U", name: $0.0, netID: $0.0, direction: $0.1) },
            nets: signalPins.map { .init(id: $0.0, pinIDs: ["U/" + $0.0]) })
        snapshot = try geometry.bind(snapshot)
        let graph = TimingDesign(topDesignName: "top", ports: [],
            instances: [.init(name: "U", cell: "INV_X1", connections: Dictionary(uniqueKeysWithValues: signalPins.map { ($0.0, $0.0) }))],
            nets: signalPins.map { .init(name: $0.0) })
        return .init(graph: graph, snapshot: snapshot, source: source, inputs: inputs, geometry: geometry, reference: reference)
    }
}
