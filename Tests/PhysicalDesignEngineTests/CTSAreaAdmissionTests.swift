import Foundation
import LayoutIR
import MaskGeometry
import PhysicalDesignEngine
import Synchronization
import Testing
@testable import PhysicalDesignCore

@Suite("CTS known conductor AREA admission", .timeLimit(.minutes(1)))
struct CTSAreaAdmissionTests {
    @Test(arguments: ["isolated", "abstract-port", "port-only", "union", "point-touch", "budget"])
    func componentAdmission(_ scenario: String) throws {
        let first = box(0, 0, 200, 300)
        let second = box(100, 0, 300, 300)
        var material = PhysicalDesignConductorMaterial(all: [first, second], constructed: [first], abstractPorts: [])
        switch scenario {
        case "isolated": material = .init(all: [first], constructed: [first], abstractPorts: [])
        case "abstract-port": material.all = [first, box(200, 0, 250, 100)]
            material.abstractPorts = [box(200, 0, 250, 100)]
        case "port-only": material = .init(all: [first], constructed: [], abstractPorts: [first])
        case "point-touch":
            let other = box(200, 300, 400, 600)
            material = .init(all: [first, other], constructed: [first], abstractPorts: [other])
        default: break
        }
        var budget = PhysicalDesignRoutingWorkBudget(caller: scenario == "budget" ? 1 : nil)
        do {
            try PhysicalDesignCTSAreaAdmission.validate(material, layer: 2, threshold: 83000, budget: &budget)
            #expect(scenario == "union" || scenario == "port-only")
        } catch let error as PhysicalDesignTechnologyError {
            switch error {
            case .invalid(let message): #expect((scenario == "isolated" || scenario == "point-touch") && message.contains("complete known conductor island"))
            case .unsupported(let message): #expect(scenario == "abstract-port" && message.contains("unproven"))
            }
        } catch let error as PhysicalDesignSourceRouter.Failure {
            #expect(scenario == "budget" && error.code == "routing_candidate_budget_exhausted")
        }
    }

    @Test func sourcePortProvenanceDistinguishesUnprovenFromBaseline() async throws {
        let support = ProcessGeometryTests()
        let (base, store) = try await support.fixtureSources(minimumArea: "0.083")
        var request = support.nativeRequest(base)
        request.stage = .clockTreeSynthesis
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let geometry = try PhysicalDesignProcessGeometry(inputs: inputs, request: request, units: 1000)
        var snapshot = try geometry.bind(try #require(request.initialSnapshot))
        // All exposed PORT-only components remain the unchanged partial baseline.
        try geometry.validateAreaStage(request, snapshot: snapshot)
        let cell = try #require(snapshot.cells.first)
        let pin = try #require(try geometry.pinShapes(master: cell.master, pin: "Y", orientation: cell.orientation,
            x: cell.x, y: cell.y).first)
        let bounds = try #require(PolygonGeometry.boundingBox(of: pin.points))
        snapshot.fills = [.init(id: "touching-abstract-port", layer: Int(pin.layer),
            geometry: .init(x: Int64(bounds.minX), y: Int64(bounds.minY), width: 50, height: 50))]
        do {
            try geometry.validateAreaStage(request, snapshot: snapshot)
            Issue.record("A deficient known component touching an abstract source PORT must remain unproven.")
        } catch let error as PhysicalDesignTechnologyError {
            guard case .unsupported(let message) = error else { throw error }
            #expect(message.contains("unproven") && message.contains("83000"))
        }
    }

    @Test func lowerCancellationRemainsCancellation() throws {
        let first = box(0, 0, 100, 700), second = box(300, 0, 400, 700)
        let material = PhysicalDesignConductorMaterial(all: [first, second], constructed: [first, second], abstractPorts: [])
        let probes = Mutex(0)
        var budget = PhysicalDesignRoutingWorkBudget(caller: nil)
        #expect(throws: CancellationError.self) {
            try PhysicalDesignCTSAreaAdmission.validate(material, layer: 2, threshold: 83000, budget: &budget,
                additionalCancellationCheck: { probes.withLock { count in count += 1; return count == 20 } })
        }
        #expect(probes.withLock { $0 } == 20 && budget.checks > 0)
    }

    @Test func nativeAPIAndCLIRejectIsolatedFillWithoutPublication() async throws {
        let support = ProcessGeometryTests()
        let (base, memory) = try await support.fixtureSources(minimumArea: "0.083")
        var request = support.nativeRequest(base)
        request.stage = .clockTreeSynthesis
        request.initialSnapshot?.cells = []
        request.initialSnapshot?.pins = []
        request.initialSnapshot?.fills = [.init(id: "isolated", layer: 2,
            geometry: .init(x: 3000, y: 3000, width: 100, height: 100))]
        // Real input bytes replace the schema-only base fixture bindings for API/CLI readback.
        let codec = PhysicalDesignJSONCodec()
        let design = try await memory.registerInput(try codec.encode(try #require(request.initialSnapshot)),
            relativePath: "inputs/cts-area-design.json", kind: .netlist, format: .json)
        let constraints = try await memory.registerInput(Data("# Geometry admission counterexample; no timing qualification.\n".utf8),
            relativePath: "inputs/cts-area-constraints.sdc", kind: .constraint, format: .sdc)
        let replaced = [request.design.artifact, request.constraints.reference]
        request.inputBindings.removeAll { replaced.contains($0.reference) }
        request.inputs.removeAll { replaced.contains($0) }
        request.design.artifact = design.reference
        request.design.designDigest = design.reference.digest.hexadecimalValue
        request.constraints = constraints
        request.inputBindings.append(contentsOf: [design, constraints])
        request.inputs.append(contentsOf: [design.reference, constraints.reference])
        let root = FileManager.default.temporaryDirectory.appending(path: "cts-area-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in request.inputBindings {
            let path = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: path)
        }
        for cli in [false, true] {
            request.runID = "cts-area-isolated-\(cli)"
            request = try codec.decode(PhysicalDesignRequest.self, from: codec.encode(request))
            let result = cli ? try await invoke(request, root: root) : try await PhysicalDesignEngine(artifactStore: memory).execute(request)
            #expect(result.status == .blocked && result.artifactBindings.isEmpty && result.payload.physicalDesign == nil)
            #expect(result.diagnostics.contains { $0.summary.contains("complete known conductor island 10000") && $0.summary.contains("83000") }, "\(result.diagnostics)")
            let bytes = try codec.encode(result)
            Attachment.record(Array(bytes), named: request.runID + "-result.json")
            let saved = root.appending(path: request.runID + "-saved.json")
            try bytes.write(to: saved)
            let retained = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: saved))
            #expect(retained.status == result.status && retained.diagnostics == result.diagnostics)
            let path = "runs/\(request.runID)/physical-design/clockTreeSynthesis/revision.json"
            if cli { #expect(!FileManager.default.fileExists(atPath: root.appending(path: path).path)) }
            else { #expect(await memory.data(at: path) == nil) }
        }
    }

    private func box(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> IRBoundary {
        .init(layer: 2, datatype: 0, points: [.init(x: x0, y: y0), .init(x: x1, y: y0),
            .init(x: x1, y: y1), .init(x: x0, y: y1), .init(x: x0, y: y0)])
    }

    private func invoke(_ request: PhysicalDesignRequest, root: URL) async throws -> PhysicalDesignResult {
        let source = root.appending(path: request.runID + ".json"), output = root.appending(path: request.runID + "-stdout.json")
        try PhysicalDesignJSONCodec().encode(request).write(to: source)
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { do { try handle.close() } catch { Issue.record(error) } }
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", source.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        let result = try PhysicalDesignJSONCodec().decode(PhysicalDesignResult.self, from: Data(contentsOf: output))
        #expect((process.terminationStatus == 0) == (result.status == .completed))
        return result
    }
}
