import CircuiteFoundation
import DRCNative
import Foundation
import PhysicalDesignEngine
import Testing
@testable import PhysicalDesignCore

@Suite("Exact source-process antenna integration", .timeLimit(.minutes(2)))
struct SourceProcessAntennaMeasurementTests {
    @Test("candidate assessment retains exact numeric source evidence", arguments: ["clean", "violated", "pwl", "multiport", "well", "unassessed"])
    func candidate(_ kind: String) async throws {
        var (request, store, _) = try await NativeRepairMeasurementTests().fixture(antenna: .reroute, sourceLaw: kind)
        request.stage = .detailedRouting
        if kind == "unassessed" { request.repairMeasurementProfile = nil }
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        guard result.status == .completed else { return }
        let evidence = try await verify(result, request: request, store: store)
        let expected: PhysicalDesignSourceAntennaMeasurementEvidence.Coverage = kind == "unassessed" ? .unassessed : kind == "violated" ? .violated : .clean
        #expect(evidence.coverage == expected)
        if kind == "unassessed" { #expect(evidence.checks.isEmpty && evidence.profile == nil); return }
        let check = try #require(evidence.checks.first)
        #expect(check.terminalDeclarations.contains { $0.pinID == "S/Y" && $0.rawDiffusionAreaSquareMicrons == nil && $0.reportedDiffusionAreaSquareMicrons == 0 && $0.diffusionOrigin == "omitted_unqualified_zero" })
        #expect(check.result.measurements.allSatisfy { $0.gateAreaSquareMicrons == 0.05 })
        if kind == "well" {
            #expect(check.nonConductorRecords.contains {
                $0.sourceID == "pin:G/W" && $0.layerID == "WELL" && $0.sourceLayerName == "pwell"
                    && $0.sourceKind == .masterslice && $0.netID == nil
            })
            #expect(check.nonConductorRecords.allSatisfy { record in !check.input.rectangles.contains { $0.id == record.recordID } })
        }
        if kind == "pwl" { #expect(check.result.measurements.allSatisfy { $0.diffusionAreaSquareMicrons == 0.1 && $0.limit == 40 }) }
        if kind == "multiport" {
            let gate = try #require(check.input.terminals.first { $0.id == "G/A" })
            #expect(gate.portRecordIDs.count == 2 && check.input.terminals.filter { $0.id == "G/A" }.count == 1)
            #expect(check.result.measurements.allSatisfy { $0.terminalIDs.filter { $0 == "G/A" }.count == 1 })
        }
    }

    @Test("repair requires actual before violation and a clean saved candidate")
    func repair() async throws {
        let (request, store, _) = try await NativeRepairMeasurementTests().fixture(antenna: .reroute, sourceLaw: "repair")
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        guard result.status == .completed else { return }
        let evidence = try await verify(result, request: request, store: store)
        #expect(evidence.coverage == .clean && evidence.checks.map(\.phase) == ["before", "candidate"])
        #expect(evidence.checks[0].result.measurements.contains { !$0.passed })
        let before = try #require(evidence.checks[0].result.measurements.first)
        #expect(before.unionAreaDBU2 == 990000 && before.gateAreaSquareMicrons == 0.05)
        #expect(abs(before.ratio - 19.8) < 1e-12 && before.limit == 18 && !before.passed)
        #expect(evidence.checks[0].result.nonGateComponents.contains {
            $0.netID == "N" && $0.reason == .noGateAtPrefix && $0.terminalIDs.isEmpty
                && Set($0.componentRecordIDs) == Set(["route:original:branch-h:4", "via:v2:8"])
        })
        #expect(evidence.checks[1].result.measurements.allSatisfy { $0.passed })
        let saved = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self,
            from: await store.read(try #require(result.payload.physicalDesign?.layoutArtifact)))
        #expect(saved.routes != request.initialSnapshot?.routes)
        #expect(saved.antennaRepairs.last?.ratioStatus == .sourceProcessLawMeasurements)
        #expect(saved.antennaRepairs.last?.resultingRatio == nil)
    }

    @Test("unsupported source coverage and bounded failures publish no candidate", arguments: ["gate", "top", "target-well", "unmapped", "domain", "model-only", "budget", "records", "clean-repair", "schema", "caller-rule", "order"])
    func refused(_ kind: String) async throws {
        var (request, store, _) = try await NativeRepairMeasurementTests().fixture(antenna: .reroute,
            sourceLaw: kind == "clean-repair" ? "twenty" : kind)
        if kind != "clean-repair" { request.stage = .detailedRouting }
        if kind == "unmapped" { request.initialSnapshot?.routes[0].segments[0].layer = 999 }
        if kind == "budget" || kind == "records" {
            let old = try #require(request.repairMeasurementProfile)
            request.repairMeasurementProfile = .init(artifact: old.artifact,
                limits: .init(maximumInputBytes: 8_000_000, maximumProjectionRecords: kind == "records" ? 1 : 10_000,
                    maximumGeometryProbes: 2_000_000, maximumBackendWork: kind == "budget" ? 1 : 2_000_000, timeoutSeconds: 30))
        }
        if kind == "schema" || kind == "caller-rule" || kind == "order" {
            let old = try #require(request.repairMeasurementProfile)
            let profileBytes = try await store.read(old.artifact)
            var object = try #require(JSONSerialization.jsonObject(with: profileBytes) as? [String: Any])
            if kind == "schema" { object["schemaVersion"] = 1 }
            if kind == "caller-rule" {
                let rule = NativeDRCRule(id: "caller-override", kind: .maximumAntennaRatio, layer: "metH", value: 99999)
                object["rules"] = try JSONSerialization.jsonObject(with: PhysicalDesignJSONCodec().encode([rule]))
            }
            if kind == "order" { object["processLayerOrder"] = ["metU", "cutVU", "metV", "cutHV", "metH"] }
            let binding = try await store.registerInput(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                relativePath: "inputs/invalid-source-profile.json", kind: .technology, format: .json)
            request.inputBindings.append(binding); request.inputs.append(binding.reference)
            request.repairMeasurementProfile = .init(artifact: binding, limits: old.limits)
        }
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
        if kind == "target-well" {
            #expect(result.diagnostics.contains { $0.summary.contains("nonconductor source layer") })
        }
        if kind == "clean-repair" {
            let tech = try #require(request.processAssets["tech"])
            let bytes = try await store.read(tech)
            #expect(String(decoding: bytes, as: UTF8.self).contains("ANTENNADIFFAREARATIO 20 ;"))
            #expect(result.diagnostics.contains { $0.summary.contains("actual before violation") })
        }
        #expect(await store.data(at: "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/revision.json") == nil)
    }

    @Test("before and after share one lower work allowance")
    func cumulativeBudget() async throws {
        var (request, store, geometry) = try await NativeRepairMeasurementTests().fixture(antenna: .reroute, sourceLaw: "repair")
        let loaded = try #require(try await NativePhysicalDesignRepairMeasurement.load(request: request, store: store))
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        let source = try PhysicalDesignAntennaSourceProjection(inputs: inputs, manifestReference: request.pdk.manifest,
            sources: request.processAssets.mapValues(\.reference), maximumRecords: loaded.reference.limits.maximumProjectionRecords)
        let first = try NativePhysicalDesignSourceAntennaMeasurement(reference: loaded.reference, profile: loaded.profile, source: source)
            .candidate(try #require(request.initialSnapshot), geometry: geometry)
        let firstWork = try #require(first.checks.first?.result.spentWork)
        request.repairMeasurementProfile = .init(artifact: loaded.reference.artifact,
            limits: .init(maximumInputBytes: 8_000_000, maximumProjectionRecords: 10_000, maximumGeometryProbes: 2_000_000,
                maximumBackendWork: firstWork, timeoutSeconds: 30))
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty, "\(result.diagnostics)")
        #expect(result.diagnostics.contains { $0.summary.contains("quota") })
    }

    @Test("cancelled source assessment publishes no candidate")
    func cancelled() async throws {
        var (request, store, _) = try await NativeRepairMeasurementTests().fixture(antenna: .reroute, sourceLaw: "clean")
        request.stage = .detailedRouting
        let task = Task { try await PhysicalDesignEngine(artifactStore: store).execute(request) }
        task.cancel()
        let result = try await task.value
        #expect(result.status == .cancelled && result.artifactBindings.isEmpty)
    }

    @Test("actual CLI persists source-process coverage and exact candidate", arguments: ["repair", "clean", "violated", "unassessed", "domain"])
    func actualCLI(_ kind: String) async throws {
        var (request, memory, _) = try await NativeRepairMeasurementTests().fixture(antenna: .reroute, sourceLaw: kind)
        if kind != "repair" { request.stage = .detailedRouting }
        if kind == "unassessed" { request.repairMeasurementProfile = nil }
        let root = FileManager.default.temporaryDirectory.appending(path: "source-antenna-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        for binding in request.inputBindings {
            let path = root.appending(path: binding.path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await memory.read(binding).write(to: path)
        }
        let path = root.appending(path: "request.json")
        try PhysicalDesignJSONCodec().encode(request).write(to: path)
        let process = Process(); process.executableURL = try PhysicalDesignCLIProcessTests().executableURL(named: "physical-design")
        process.arguments = ["--request", path.path, "--project-root", root.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let result = try PhysicalDesignJSONCodec().decode(PhysicalDesignResult.self, from: bytes)
        if kind == "domain" {
            #expect(process.terminationStatus != 0 && result.status == .blocked && result.artifactBindings.isEmpty)
        } else {
            #expect(process.terminationStatus == 0 && result.status == .completed, "\(result.diagnostics)")
            guard result.status == .completed else { return }
            _ = try await verify(result, request: request, store: FileSystemPhysicalDesignArtifactStore(projectRoot: root))
        }
    }

    private func verify(_ result: PhysicalDesignResult, request: PhysicalDesignRequest,
                        store: any PhysicalDesignArtifactStore) async throws -> PhysicalDesignSourceAntennaMeasurementEvidence {
        #expect(result.payload.claims.production == .blocked)
        let manifestBinding = try #require(result.artifactBindings.first { $0.logicalID.hasSuffix("manifest") })
        let bytes = try await store.read(manifestBinding)
        let manifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self, from: bytes)
        #expect(manifest.validationDiagnostics().isEmpty)
        #expect(manifest.implementationVersion == "1.12.0")
        let evidence = try #require(manifest.sourceAntennaMeasurementEvidence)
        #expect(evidence.processManifest == request.pdk.manifest && evidence.processAssets == request.processAssets.mapValues(\.reference))
        #expect(evidence.candidateSnapshotDigest == result.payload.physicalDesign?.layoutArtifact.reference.digest)
        let snapshotBytes = try await store.read(try #require(result.payload.physicalDesign?.layoutArtifact))
        let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: snapshotBytes)
        #expect(try PhysicalDesignJSONCodec().encode(snapshot) == snapshotBytes)
        for check in evidence.checks {
            var budget = try NativeSourceAntennaBudget(limits: .init(maximumInputRecords: 10000, maximumResults: 10000,
                maximumWork: 2_000_000, maximumStorageEntries: 10000))
            let replay = try NativeSourceAntennaEvaluator().evaluate(check.input, budget: &budget, isCancelled: { false })
            #expect(replay.measurements == check.result.measurements)
            #expect(replay.nonGateComponents == check.result.nonGateComponents)
        }
        var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        old.removeValue(forKey: "sourceAntennaMeasurementEvidence")
        let oldManifest = try PhysicalDesignJSONCodec().decode(PhysicalDesignRunManifest.self,
            from: JSONSerialization.data(withJSONObject: old, options: [.sortedKeys]))
        #expect(oldManifest.sourceAntennaMeasurementEvidence == nil)
        return evidence
    }
}
