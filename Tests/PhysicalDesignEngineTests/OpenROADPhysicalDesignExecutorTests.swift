import CircuiteFoundation
import Foundation
import LogicIR
import OpenROADPhysicalDesign
import PDKCore
import PhysicalDesignCore
import SignoffToolSupport
import Testing

@Suite("OpenROAD production process contract")
struct OpenROADPhysicalDesignExecutorTests {
    @Test
    func missingExecutableIsBlocked() async throws {
        let fixture = try await Fixture.make(runID: "openroad-missing", executableMode: .missing)
        let executor = OpenROADPhysicalDesignExecutor(
            artifactStore: fixture.store,
            scratchRoot: fixture.root
        )

        let result = try await executor.execute(fixture.request)

        #expect(result.status == .blocked)
        #expect(result.diagnostics.map { $0.code.rawValue }.contains("openroad_executable_unavailable"))
        #expect(result.payload.claims.production == .blocked)
        fixture.remove()
    }

    @Test
    func processContractRetainsDEFAndEvidenceWithoutSelfQualification() async throws {
        let fixture = try await Fixture.make(runID: "openroad-success", executableMode: .successful)
        let executor = OpenROADPhysicalDesignExecutor(
            artifactStore: fixture.store,
            scratchRoot: fixture.root
        )

        let result = try await executor.execute(fixture.request)

        #expect(result.status == .completed)
        #expect(result.provenance.invocation?.mode == .externalProcess)
        #expect(result.provenance.supportingTools == [try ProducerIdentity(
            kind: .tool,
            identifier: fixture.executable.toolID,
            version: fixture.executable.expectedVersion,
            build: fixture.executable.digest.hexadecimalValue
        )])
        #expect(result.payload.claims.geometry == .verified)
        #expect(result.payload.claims.timing == .blocked)
        #expect(result.payload.claims.production == .blocked)
        #expect(result.artifacts.contains { $0.path.hasSuffix("openroad-output.def") })
        let evidenceReference = try #require(result.artifacts.first { $0.path.hasSuffix("process-evidence.json") })
        let evidenceData = try await fixture.store.read(evidenceReference)
        let evidence = try PhysicalDesignJSONCodec().decode(PhysicalDesignProcessEvidence.self, from: evidenceData)
        #expect(evidence.backendID == "openroad")
        #expect(evidence.observedVersion.contains("fixture-2.0"))
        #expect(evidence.exitCode == 0)
        #expect(evidence.outputs.contains { $0.format == .def })
        #expect(evidence.executable.digest == fixture.executable.digest)
        let completionReference = try #require(result.payload.stageCompletionEvidence)
        let completionData = try await fixture.store.read(completionReference)
        let completion = try PhysicalDesignJSONCodec().decode(
            PhysicalDesignStageCompletionEvidence.self,
            from: completionData
        )
        #expect(completion.isValid)
        #expect(completion.stage == .floorplan)
        #expect(completion.metrics.contains { $0.name == "coreArea" && $0.value == 640_000 })
        fixture.remove()
    }

    @Test
    func nonzeroExitRetainsProcessFailureEvidence() async throws {
        let fixture = try await Fixture.make(runID: "openroad-failure", executableMode: .failing)
        let executor = OpenROADPhysicalDesignExecutor(
            artifactStore: fixture.store,
            scratchRoot: fixture.root
        )

        let result = try await executor.execute(fixture.request)

        #expect(result.status == .failed)
        #expect(result.diagnostics.map { $0.code.rawValue }.contains("openroad_nonzero_exit"))
        #expect(result.artifacts.contains { $0.path.hasSuffix("openroad-stdout.log") })
        #expect(result.artifacts.contains { $0.path.hasSuffix("openroad-stderr.log") })
        let evidenceReference = try #require(result.artifacts.first { $0.path.hasSuffix("process-evidence.json") })
        let evidenceData = try await fixture.store.read(evidenceReference)
        let evidence = try PhysicalDesignJSONCodec().decode(PhysicalDesignProcessEvidence.self, from: evidenceData)
        #expect(evidence.exitCode == 9)
        #expect(evidence.outputs.isEmpty)
        fixture.remove()
    }

    @Test
    func timeoutRetainsCapturedProcessEvidence() async throws {
        let fixture = try await Fixture.make(runID: "openroad-timeout", executableMode: .successful)
        let executor = OpenROADPhysicalDesignExecutor(
            artifactStore: fixture.store,
            processRunner: TimeoutProcessRunner(),
            scratchRoot: fixture.root
        )

        let result = try await executor.execute(fixture.request)

        #expect(result.status == .failed)
        #expect(result.diagnostics.map { $0.code.rawValue }.contains("openroad_execution_timed_out"))
        let evidenceReference = try #require(result.artifacts.first { $0.path.hasSuffix("process-evidence.json") })
        let evidenceData = try await fixture.store.read(evidenceReference)
        let evidence = try PhysicalDesignJSONCodec().decode(PhysicalDesignProcessEvidence.self, from: evidenceData)
        #expect(evidence.termination == .timedOut)
        #expect(evidence.exitCode == nil)
        let stdout = try await fixture.store.read(evidence.standardOutput)
        let stderr = try await fixture.store.read(evidence.standardError)
        #expect(String(decoding: stdout, as: UTF8.self) == "partial output")
        #expect(String(decoding: stderr, as: UTF8.self) == "deadline reached")
        fixture.remove()
    }

    private struct TimeoutProcessRunner: TimedProcessRunning {
        func run(
            process: Process,
            cancellationCheck: (@Sendable () async throws -> Bool)?
        ) async throws -> TimedProcessResult {
            if process.arguments == ["-version"] {
                return TimedProcessResult(
                    exitCode: 0,
                    standardOutput: "OpenROAD fixture-2.0",
                    standardError: ""
                )
            }
            throw TimedProcessError.timedOut(
                executablePath: process.executableURL?.path(percentEncoded: false) ?? "openroad",
                timeoutSeconds: 1,
                standardOutput: "partial output",
                standardError: "deadline reached"
            )
        }
    }

    private struct Fixture: Sendable {
        enum ExecutableMode: Sendable {
            case missing
            case successful
            case failing
        }

        let root: URL
        let store: InMemoryPhysicalDesignArtifactStore
        let request: PhysicalDesignRequest
        let executable: PhysicalDesignExecutableReference

        static func make(runID: String, executableMode: ExecutableMode) async throws -> Self {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "physical-design-openroad-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executableURL = root.appending(path: "openroad-fixture")
            let executableData: Data
            switch executableMode {
            case .missing:
                executableData = Data("#!/bin/sh\nexit 0\n".utf8)
            case .successful:
                let output = PhysicalDesignDEFWriter().write(outputSnapshot())
                executableData = Data(
                    """
                    #!/bin/sh
                    if [ "$1" = "-version" ]; then
                      echo "OpenROAD fixture-2.0"
                      exit 0
                    fi
                    cat > output.def <<'XCIRCUITE_DEF'
                    \(output)
                    XCIRCUITE_DEF
                    cat > stage-completion.txt <<'XCIRCUITE_STAGE'
                    floorplan
                    coreArea=640000
                    XCIRCUITE_STAGE
                    echo "fixture physical implementation completed"
                    exit 0
                    """.utf8
                )
            case .failing:
                executableData = Data(
                    """
                    #!/bin/sh
                    if [ "$1" = "-version" ]; then
                      echo "OpenROAD fixture-2.0"
                      exit 0
                    fi
                    echo "fixture failed" >&2
                    exit 9
                    """.utf8
                )
            }
            if executableMode != .missing {
                try executableData.write(to: executableURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: executableURL.path(percentEncoded: false)
                )
            }
            let executable = try PhysicalDesignExecutableReference(
                path: executableURL.path(percentEncoded: false),
                toolID: "openroad",
                expectedVersion: "fixture-2.0",
                digest: SHA256ContentDigester().digest(data: executableData, using: .sha256),
                byteCount: UInt64(executableData.count)
            )

            let store = InMemoryPhysicalDesignArtifactStore()
            let designData = Data("{\"top\":\"fixture_top\"}\n".utf8)
            let design = try await store.registerInput(
                designData,
                relativePath: "inputs/design.json",
                kind: .netlist,
                format: .json
            )
            let constraints = try await store.registerInput(
                Data("create_clock -period 10 [get_ports clk]\n".utf8),
                relativePath: "inputs/constraints.sdc",
                kind: .constraint,
                format: .sdc
            )
            let pdk = try await store.registerInput(
                Data("{\"schemaVersion\":1,\"processID\":\"fixture\"}\n".utf8),
                relativePath: "inputs/pdk.json",
                kind: .technology,
                format: .json
            )
            let technologyLEF = try await store.registerInput(
                Data("VERSION 5.8 ;\nEND LIBRARY\n".utf8),
                relativePath: "inputs/technology.lef",
                kind: .technology,
                format: .lef
            )
            let cellLEF = try await store.registerInput(
                Data("VERSION 5.8 ;\nMACRO BUF_X1\nEND BUF_X1\nEND LIBRARY\n".utf8),
                relativePath: "inputs/cells.lef",
                kind: .technology,
                format: .lef
            )
            let liberty = try await store.registerInput(
                Data("library(fixture) { time_unit : \"1ns\"; }\n".utf8),
                relativePath: "inputs/cells.lib",
                kind: .timingLibrary,
                format: .liberty
            )
            let netlist = try await store.registerInput(
                Data("module fixture_top(input clk); endmodule\n".utf8),
                relativePath: "inputs/design.v",
                kind: .netlist,
                format: .verilog
            )
            let rcSetup = try await store.registerInput(
                Data("set_wire_rc -signal -resistance 1 -capacitance 1\n".utf8),
                relativePath: "inputs/rc-setup.tcl",
                kind: .constraint,
                format: .text
            )
            let stageScript = try await store.registerInput(
                Data(
                    """
                    initialize_floorplan -utilization 50 -aspect_ratio 1 -core_space 10
                    set ::xcircuite_completed_stage floorplan
                    set ::xcircuite_stage_metrics [dict create coreArea 640000]
                    """.utf8
                ),
                relativePath: "inputs/floorplan.tcl",
                kind: .constraint,
                format: .text
            )
            let productionConfiguration = try PhysicalDesignProductionConfiguration(
                executable: executable,
                technologyLEFs: [technologyLEF],
                cellLEFs: [cellLEF],
                libertyLibraries: [liberty],
                synthesizedNetlist: netlist,
                rcSetupScript: rcSetup,
                stageScript: stageScript,
                cornerID: "tt"
            )
            let request = PhysicalDesignRequest(
                runID: runID,
                inputs: [],
                design: LogicDesignReference(
                    artifact: design,
                    topDesignName: "fixture_top",
                    designDigest: design.digest.hexadecimalValue
                ),
                constraints: constraints,
                requestedModeIDs: ["functional"],
                pdk: PDKReference(
                    manifest: pdk,
                    processID: "fixture",
                    version: "1",
                    digest: pdk.digest.hexadecimalValue
                ),
                stage: .floorplan,
                configuration: PhysicalDesignConfiguration.default,
                initialSnapshot: PhysicalDesignSnapshot.empty(topCell: "fixture_top"),
                executionIntent: .productionImplementation,
                productionConfiguration: productionConfiguration
            )
            return Self(root: root, store: store, request: request, executable: executable)
        }

        func remove() {
            do {
                if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: root)
                }
            } catch {
                Issue.record("Failed to remove OpenROAD test fixture: \(error.localizedDescription)")
            }
        }

        private static func outputSnapshot() -> PhysicalDesignSnapshot {
            PhysicalDesignSnapshot(
                topCell: "fixture_top",
                die: .init(x: 0, y: 0, width: 100_000, height: 100_000),
                core: .init(x: 10_000, y: 10_000, width: 80_000, height: 80_000),
                rows: [.init(id: "ROW_0", originX: 10_000, originY: 10_000, siteWidth: 100, height: 1_000, siteCount: 800)]
            )
        }
    }
}
