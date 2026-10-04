import Foundation
import PhysicalDesignCore
import PhysicalDesignEngine
import PlacementEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Bounded legal placement")
struct LegalPlacementTests {
    @Test("actual native source-bound placement finds legal occupied-boundary and orientation candidates", .timeLimit(.minutes(1)), arguments: ["locked", "blockage", "orientation"])
    func occupiedBoundaryPlacement(_ scenario: String) async throws {
        let fixture = try await prepared(scenario)
        let request = fixture.request
        let input = try #require(request.initialSnapshot)
        let result = try await NativePlacementEngine(artifactStore: fixture.store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let reference = try #require(result.payload.physicalDesign)
        let output = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await fixture.store.read(reference.layoutArtifact))
        try fixture.geometry.validate(output)
        #expect(output.processManifest == fixture.geometry.manifestReference)
        #expect(output.processAssets == fixture.geometry.sources)
        #expect(output.cells.filter(\.locked) == input.cells.filter(\.locked))
        #expect(output.pins.filter { $0.cellID == "Z_locked" } == input.pins.filter { $0.cellID == "Z_locked" })
        #expect(output.pins.map(\.cellID) == input.pins.map(\.cellID))
        #expect(output.pins.map(\.name) == input.pins.map(\.name))
        #expect(output.pins.map(\.id) == input.pins.map(\.id))
        #expect(output.pins.map(\.netID) == input.pins.map(\.netID))
        #expect(output.nets == input.nets)
        let cell = try #require(output.cells.first { $0.id == "U1" })
        if scenario == "blockage" { #expect(cell.x == 2100) }
        if scenario == "locked" { #expect(cell.x == 2200) }
        if scenario == "orientation" {
            #expect(cell.y == 1000)
            #expect(cell.orientation == .s || cell.orientation == .fs)
            #expect(output.pins.first?.y != input.pins.first?.y)
        }
        #expect(output.implementationState?.placementProof?.legalCellCount == output.cells.count)
        #expect(result.payload.claims.timing == (result.status == .completed ? .notApplicable : .blocked) && result.payload.claims.production == .blocked)
        for artifact in result.artifactBindings { _ = try await fixture.store.read(artifact) }
    }

    @Test("bounded placement rejects capacity, caller ceiling, overflow and invalid fixed occupancy without artifacts", .timeLimit(.minutes(1)), arguments: ["capacity", "budget", "overflow", "locked-overlap", "locked-unplaced"])
    func placementRejections(_ failure: String) async throws {
        let fixture = try await prepared(failure == "capacity" ? "blockage" : "locked")
        var request = fixture.request
        var snapshot = try #require(request.initialSnapshot)
        let code: String
        switch failure {
        case "capacity":
            snapshot.blockages[0].width = 4100
            code = "placement_capacity_exceeded"
        case "budget":
            request.configuration.maximumPlacementCandidateChecks = 1
            code = "placement_candidate_budget_exceeded"
        case "overflow":
            request.configuration.placementSpacing = .max
            code = "placement_arithmetic_overflow"
        case "locked-overlap":
            var locked = snapshot.cells[1]
            locked.id = "ZZ_locked"
            snapshot.cells.append(locked)
            code = "locked_cell_placement_invalid"
        default:
            snapshot.cells[1].placed = false
            code = "locked_cell_placement_invalid"
        }
        request.initialSnapshot = snapshot
        let result = try await NativePlacementEngine(artifactStore: fixture.store).execute(request)
        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == code }, "\(result.diagnostics)")
        #expect(result.artifactBindings.isEmpty && result.payload.physicalDesign == nil)
        #expect(request.initialSnapshot == snapshot)
    }

    @Test("legal geometry does not admit timing-driven or production placement", .timeLimit(.minutes(1)), arguments: [PhysicalDesignExecutionIntent.characterizedTiming, .productionImplementation])
    func unqualifiedPlacement(_ intent: PhysicalDesignExecutionIntent) async throws {
        let fixture = try await prepared("locked")
        var request = fixture.request
        request.executionIntent = intent
        let result = try await NativePlacementEngine(artifactStore: fixture.store).execute(request)
        let code = intent == .characterizedTiming ? "native_characterized_timing_stage_unsupported" : "native_production_implementation_unsupported"
        #expect(result.status == .blocked)
        #expect(result.diagnostics.contains { $0.code.rawValue == code })
        #expect(result.artifactBindings.isEmpty)
    }

    @Test("cancelled native placement publishes no artifacts", .timeLimit(.minutes(1)))
    func cancelledPlacement() async throws {
        let fixture = try await prepared("locked")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativePlacementEngine(artifactStore: fixture.store).execute(fixture.request)
        }
        let result = try await task.value
        #expect(result.status == .cancelled)
        #expect(result.artifactBindings.isEmpty)
    }

    @Test("candidate work follows occupied boundaries instead of site count", .timeLimit(.minutes(1)))
    func structuralCandidateWork() async throws {
        let fixture = try await prepared("locked")
        var request = fixture.request
        request.configuration.maximumPlacementCandidateChecks = 2
        let small = try await NativePlacementEngine(artifactStore: fixture.store).execute(request)
        var snapshot = try #require(request.initialSnapshot)
        snapshot.rows[0].siteCount = 10_000_000
        snapshot.core?.width = 1_000_000_000
        snapshot.die?.width = 1_000_000_000
        request.initialSnapshot = snapshot
        request.runID = "legal-placement-large-site-count"
        let large = try await NativePlacementEngine(artifactStore: fixture.store).execute(request)
        #expect(small.status == .completed && large.status == .completed, "\(large.diagnostics)")
        for name in ["placementCandidateChecks", "placementCandidateCeiling", "placementStructuralCeiling"] {
            #expect(small.payload.metrics.first { $0.name == name }?.value == large.payload.metrics.first { $0.name == name }?.value)
        }
        #expect(large.payload.metrics.first { $0.name == "placementCandidateChecks" }?.value == 2)
        #expect(large.payload.metrics.first { $0.name == "placementCandidateCeiling" }?.value == 2)
        #expect(large.payload.metrics.first { $0.name == "placementStructuralCeiling" }?.value == 48)
    }

    @Test("actual CLI retains exact source-bound legal placement or explicit caller-budget failure", .timeLimit(.minutes(1)), arguments: [false, true])
    func placementCLI(_ exhaustedBudget: Bool) async throws {
        let fixture = try await prepared("locked")
        var request = fixture.request
        if exhaustedBudget { request.configuration.maximumPlacementCandidateChecks = 1 }
        let root = FileManager.default.temporaryDirectory.appending(path: "legal-placement-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("CLI cleanup failed: \(error)") }
        }
        for binding in request.inputBindings {
            let target = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fixture.store.read(binding).write(to: target)
        }
        let codec = PhysicalDesignJSONCodec()
        let requestURL = root.appending(path: "request.json")
        try codec.encode(request).write(to: requestURL)
        let outputURL = root.appending(path: "result.json")
        #expect(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { do { try handle.close() } catch { Issue.record("CLI output close failed: \(error)") } }
        let process = Process()
        process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", requestURL.path, "--project-root", root.path]
        process.standardOutput = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        process.waitUntilExit()
        let result = try codec.decode(PhysicalDesignResult.self, from: Data(contentsOf: outputURL))
        if exhaustedBudget {
            #expect(process.terminationStatus != 0 && result.status == .blocked)
            #expect(result.diagnostics.contains { $0.code.rawValue == "placement_candidate_budget_exceeded" })
            #expect(result.artifactBindings.isEmpty)
        } else {
            #expect(process.terminationStatus == 0 && result.status == .completed)
            let reference = try #require(result.payload.physicalDesign)
            let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
            let output = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
            try fixture.geometry.validate(output)
            #expect(output.cells.first { $0.id == "U1" }?.x == 2200)
            #expect(output.processManifest == fixture.geometry.manifestReference)
            #expect(output.processAssets == fixture.geometry.sources)
            #expect(output.pins.map(\.netID) == request.initialSnapshot?.pins.map(\.netID))
            for binding in result.artifactBindings { _ = try await store.read(binding) }
            let def = try #require(result.artifactBindings.first { $0.path.hasSuffix(".def") })
            let bytes = try await store.read(def)
            #expect(String(decoding: bytes, as: UTF8.self).contains("( 2200 0 ) FN"))
        }
        #expect(result.payload.claims.timing == (result.status == .completed ? .notApplicable : .blocked) && result.payload.claims.production == .blocked)
    }

    private func prepared(_ scenario: String) async throws -> PlacementFixture {
        let support = ProcessGeometryTests()
        let (geometry, base, store) = try await support.fixture("site-y")
        var request = support.nativeRequest(base)
        let design = try await store.registerInput(Data("module fixture_top(); wire N; INV_X1 U1(.Y(N)); INV_X1 Z_locked(); endmodule\n".utf8),
            relativePath: "inputs/mapped.v", kind: .netlist, format: .verilog)
        let constraints = try await store.registerInput(Data("# Geometry allocation only. No characterized timing claim.\n".utf8),
            relativePath: "inputs/placement.sdc", kind: .constraint, format: .sdc)
        request = PhysicalDesignRequest(runID: request.runID,
            inputBindings: base.inputBindings.filter { $0.reference == base.pdk.manifest } + [design, constraints],
            design: .init(artifact: design.reference, topDesignName: base.design.topDesignName,
                designDigest: design.reference.digest.hexadecimalValue), constraints: constraints,
            requestedModeIDs: base.requestedModeIDs, pdk: base.pdk, configuration: request.configuration,
            initialSnapshot: request.initialSnapshot, processAssets: base.processAssets)
        request.runID = "legal-placement-floorplan-\(scenario)"
        let floorplan = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        let reference = try #require(floorplan.payload.physicalDesign)
        var snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(reference.layoutArtifact))
        snapshot.rows = Array(snapshot.rows.prefix(1))
        snapshot.pins[0].netID = "N"
        snapshot.nets = [.init(id: "N", pinIDs: [snapshot.pins[0].id])]
        if scenario == "blockage" {
            snapshot.rows[0].siteCount = 41
            snapshot.blockages = [.init(x: 0, y: 0, width: 2100, height: 1000)]
        } else {
            var locked = snapshot.cells[0]
            locked.id = "Z_locked"
            locked.x = 0
            locked.y = 0
            locked.placed = true
            locked.locked = true
            snapshot.cells.append(locked)
            var pin = snapshot.pins[0]
            pin.id = "Z_locked/Y"
            pin.cellID = locked.id
            pin.x = 1700
            pin.y = 200
            pin.netID = nil
            snapshot.pins.append(pin)
            if scenario == "orientation" {
                snapshot.rows[0].siteCount = 20
                var row = snapshot.rows[0]
                row.id = "row_1"
                row.originY = 1000
                row.orientation = .fs
                snapshot.rows.append(row)
            }
        }
        request.runID = "legal-placement-\(scenario)"
        request.stage = .placement
        request.initialSnapshot = snapshot
        return PlacementFixture(geometry: geometry, request: request, store: store)
    }

    private struct PlacementFixture {
        let geometry: PhysicalDesignProcessGeometry
        let request: PhysicalDesignRequest
        let store: InMemoryPhysicalDesignArtifactStore
    }
}
