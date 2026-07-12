import Foundation
import XcircuitePackage

public struct NativePhysicalDesignExecutor: PhysicalDesignStageExecuting {
    public let expectedStage: PhysicalDesignStage?
    public let allowedStages: Set<PhysicalDesignStage>?
    public let artifactStore: any PhysicalDesignArtifactStore
    public let implementationID: String
    public let implementationVersion: String

    private let mutationEngine: PhysicalDesignNativeMutationEngine
    private let codec: PhysicalDesignJSONCodec
    private let diffBuilder: PhysicalDesignDiffBuilder
    private let defWriter: PhysicalDesignDEFWriter
    private let defParser: PhysicalDesignDEFParser
    private let hasher: XcircuiteHasher

    public init(
        expectedStage: PhysicalDesignStage? = nil,
        allowedStages: Set<PhysicalDesignStage>? = nil,
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-native",
        implementationVersion: String = "1.0.0"
    ) {
        self.expectedStage = expectedStage
        self.allowedStages = allowedStages ?? expectedStage.map { [$0] }
        self.artifactStore = artifactStore
        self.implementationID = implementationID
        self.implementationVersion = implementationVersion
        self.mutationEngine = PhysicalDesignNativeMutationEngine()
        self.codec = PhysicalDesignJSONCodec()
        self.diffBuilder = PhysicalDesignDiffBuilder()
        self.defWriter = PhysicalDesignDEFWriter()
        self.defParser = PhysicalDesignDEFParser()
        self.hasher = XcircuiteHasher()
    }

    public func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload> {
        let startedAt = Date()
        if let allowedStages, !allowedStages.contains(request.stage) {
            let expectedStage = allowedStages.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ", ")
            return envelope(
                request: request,
                status: .blocked,
                diagnostics: [diagnostic(
                    severity: .error,
                    code: "stage_mismatch",
                    message: "This executor accepts [\(expectedStage)], but the request targets \(request.stage.rawValue).",
                    actions: ["use_the_executor_for_the_requested_stage"]
                )],
                payload: emptyPayload,
                startedAt: startedAt
            )
        }

        let requestDiagnostics = validate(request)
        guard requestDiagnostics.isEmpty else {
            return envelope(
                request: request,
                status: .blocked,
                diagnostics: requestDiagnostics,
                payload: emptyPayload,
                startedAt: startedAt
            )
        }

        do {
            try Task.checkCancellation()
            let loaded = try await loadSnapshot(from: request)
            try Task.checkCancellation()
            let outcome = await mutationEngine.apply(request, to: loaded.snapshot)
            switch outcome.status {
            case .blocked, .cancelled:
                return envelope(
                    request: request,
                    status: outcome.status,
                    diagnostics: outcome.diagnostics,
                    payload: PhysicalDesignPayload(
                        physicalDesign: request.inputLayout,
                        changedObjectCount: 0,
                        candidateActions: outcome.candidateActions,
                        metrics: outcome.metrics
                    ),
                    startedAt: startedAt,
                    seed: request.configuration.deterministicSeed
                )
            case .failed:
                return envelope(
                    request: request,
                    status: .failed,
                    diagnostics: outcome.diagnostics,
                    payload: emptyPayload,
                    startedAt: startedAt,
                    seed: request.configuration.deterministicSeed
                )
            case .completed:
                guard let output = outcome.snapshot else {
                    return envelope(
                        request: request,
                        status: .failed,
                        diagnostics: [diagnostic(
                            severity: .error,
                            code: "completed_without_snapshot",
                            message: "The native mutation reported completion without a physical snapshot.",
                            actions: ["inspect_native_backend"]
                        )],
                        payload: emptyPayload,
                        startedAt: startedAt,
                        seed: request.configuration.deterministicSeed
                    )
                }
                return try await persist(
                    request: request,
                    before: loaded.snapshot,
                    output: output,
                    outcome: outcome,
                    startedAt: startedAt,
                    source: loaded
                )
            }
        } catch is CancellationError {
            return envelope(
                request: request,
                status: .cancelled,
                diagnostics: [diagnostic(
                    severity: .warning,
                    code: "execution_cancelled",
                    message: "Physical design execution was cancelled before an immutable revision was committed.",
                    actions: ["resume_from_the_last_immutable_revision"]
                )],
                payload: emptyPayload,
                startedAt: startedAt,
                seed: request.configuration.deterministicSeed
            )
        } catch let error as PhysicalDesignDEFParseError {
            return envelope(
                request: request,
                status: .blocked,
                diagnostics: error.diagnostics.map(defDiagnostic),
                payload: emptyPayload,
                startedAt: startedAt,
                seed: request.configuration.deterministicSeed
            )
        } catch {
            return envelope(
                request: request,
                status: .failed,
                diagnostics: [diagnostic(
                    severity: .error,
                    code: "execution_failed",
                    message: error.localizedDescription,
                    actions: ["inspect_artifact_and_backend_diagnostics", "retry_after_repairing_inputs"]
                )],
                payload: emptyPayload,
                startedAt: startedAt,
                seed: request.configuration.deterministicSeed
            )
        }
    }

    private func loadSnapshot(from request: PhysicalDesignRequest) async throws -> LoadedSnapshot {
        if request.inputLayout != nil && request.initialSnapshot != nil {
            throw PhysicalDesignStoreError.readFailed("request contains both inputLayout and initialSnapshot")
        }
        if let reference = request.inputLayout {
            guard reference.layoutArtifact.format == .json || reference.layoutArtifact.format == .def else {
                throw PhysicalDesignStoreError.readFailed("native backend accepts canonical JSON or supported DEF layout artifacts only")
            }
            let data = try await artifactStore.read(reference.layoutArtifact)
            let sourceDigest = hasher.sha256(data: data)
            let snapshot: PhysicalDesignSnapshot
            let sourceParserID: String
            let sourceParserVersion: String
            let sourceDiagnostics: [PhysicalDesignDEFDiagnostic]
            if reference.layoutArtifact.format == .json {
                snapshot = try codec.decode(PhysicalDesignSnapshot.self, from: data)
                sourceParserID = "physical-design-json-codec"
                sourceParserVersion = "1.0.0"
                sourceDiagnostics = []
            } else {
                let parseResult = defParser.parse(data)
                guard let parsedSnapshot = parseResult.snapshot else {
                    throw PhysicalDesignDEFParseError(diagnostics: parseResult.diagnostics)
                }
                snapshot = parsedSnapshot
                sourceParserID = PhysicalDesignDEFParser.parserID
                sourceParserVersion = PhysicalDesignDEFParser.parserVersion
                sourceDiagnostics = parseResult.diagnostics
            }
            guard snapshot.topCell == reference.topCell else {
                throw PhysicalDesignStoreError.readFailed("layout top cell does not match the physical design reference")
            }
            guard reference.layoutDigest.isEmpty || reference.layoutDigest == sourceDigest else {
                throw PhysicalDesignStoreError.readFailed("layout digest does not match the source layout artifact")
            }
            return LoadedSnapshot(
                snapshot: snapshot,
                baseReference: reference,
                sourceLayoutFormat: reference.layoutArtifact.format,
                sourceLayoutDigest: sourceDigest,
                sourceParserID: sourceParserID,
                sourceParserVersion: sourceParserVersion,
                sourceDiagnostics: sourceDiagnostics
            )
        }
        if let snapshot = request.initialSnapshot {
            return LoadedSnapshot(
                snapshot: snapshot,
                baseReference: nil,
                sourceLayoutFormat: nil,
                sourceLayoutDigest: nil,
                sourceParserID: nil,
                sourceParserVersion: nil,
                sourceDiagnostics: []
            )
        }
        throw PhysicalDesignStoreError.readFailed("a canonical physical snapshot is required")
    }

    private func persist(
        request: PhysicalDesignRequest,
        before: PhysicalDesignSnapshot,
        output: PhysicalDesignSnapshot,
        outcome: PhysicalDesignNativeMutationEngine.Outcome,
        startedAt: Date,
        source: LoadedSnapshot
    ) async throws -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload> {
        let snapshotData = try codec.encode(output)
        let snapshotPath = "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/revision.json"
        let snapshotReference = try await artifactStore.write(
            snapshotData,
            relativePath: snapshotPath,
            kind: .layout,
            format: .json,
            runID: request.runID
        )

        let defData = Data(defWriter.write(output).utf8)
        let defPath = "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/revision.def"
        let defReference = try await artifactStore.write(
            defData,
            relativePath: defPath,
            kind: .layout,
            format: .def,
            runID: request.runID
        )

        let physicalReference = PhysicalDesignReference(
            layoutArtifact: snapshotReference,
            topCell: output.topCell,
            layoutDigest: snapshotReference.sha256 ?? hasher.sha256(data: snapshotData)
        )
        let diff = try diffBuilder.build(
            runID: request.runID,
            stage: request.stage,
            actor: implementationID,
            before: before,
            after: output,
            baseSnapshot: request.inputLayout?.layoutArtifact,
            proposedSnapshot: snapshotReference
        )
        let diffData = try codec.encode(diff)
        let diffPath = "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/design-diff.json"
        let diffReference = try await artifactStore.write(
            diffData,
            relativePath: diffPath,
            kind: .designDiff,
            format: .json,
            runID: request.runID
        )

        let completedAt = Date()
        let manifest = PhysicalDesignRunManifest(
            runID: request.runID,
            stage: request.stage,
            status: .completed,
            design: request.design,
            constraints: request.constraints,
            pdk: request.pdk,
            baseLayout: request.inputLayout,
            proposedLayout: physicalReference,
            designDiff: diffReference,
            artifacts: [snapshotReference, defReference, diffReference],
            implementationID: implementationID,
            implementationVersion: implementationVersion,
            deterministicSeed: request.configuration.deterministicSeed,
            createdAt: startedAt,
            completedAt: completedAt,
            sourceLayoutFormat: source.sourceLayoutFormat,
            sourceLayoutDigest: source.sourceLayoutDigest,
            sourceParserID: source.sourceParserID,
            sourceParserVersion: source.sourceParserVersion
        )
        let manifestDiagnostics = manifest.validationDiagnostics()
        guard manifestDiagnostics.isEmpty else {
            throw PhysicalDesignStoreError.writeFailed(
                "run manifest validation failed: \(manifestDiagnostics.joined(separator: "; "))"
            )
        }
        let manifestData = try codec.encode(manifest)
        let manifestPath = "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/run-manifest.json"
        let manifestReference = try await artifactStore.write(
            manifestData,
            relativePath: manifestPath,
            kind: .report,
            format: .json,
            runID: request.runID
        )

        let changedObjectCount = changedObjectCount(before: before, after: output)
        let payload = PhysicalDesignPayload(
            physicalDesign: physicalReference,
            changedObjectCount: changedObjectCount,
            candidateActions: outcome.candidateActions,
            designDiff: diffReference,
            metrics: outcome.metrics,
            runManifest: manifestReference
        )
        return envelope(
            request: request,
            status: .completed,
            diagnostics: source.sourceDiagnostics.map(defDiagnostic) + outcome.diagnostics,
            payload: payload,
            artifacts: [snapshotReference, defReference, diffReference, manifestReference],
            startedAt: startedAt,
            seed: request.configuration.deterministicSeed
        )
    }

    private func validate(_ request: PhysicalDesignRequest) -> [XcircuiteEngineDiagnostic] {
        var diagnostics: [XcircuiteEngineDiagnostic] = []
        if request.schemaVersion != PhysicalDesignRequest.currentSchemaVersion {
            diagnostics.append(diagnostic(severity: .error, code: "unsupported_request_schema", message: "Request schema version \(request.schemaVersion) is not supported.", actions: ["upgrade_the_request_schema"]))
        }
        if request.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(diagnostic(severity: .error, code: "run_id_missing", message: "A non-empty run ID is required for immutable artifact provenance.", actions: ["set_run_id"]))
        }
        if request.design.topDesignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(diagnostic(severity: .error, code: "top_design_missing", message: "A top design name is required.", actions: ["set_top_design_name"]))
        }
        if request.design.designDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(diagnostic(severity: .error, code: "design_digest_missing", message: "The mapped design digest is required for reproducibility.", actions: ["record_design_digest"]))
        }
        if request.constraints.modeIDs.isEmpty {
            diagnostics.append(diagnostic(severity: .error, code: "timing_mode_missing", message: "At least one timing mode is required for physical implementation.", actions: ["declare_timing_modes"]))
        }
        if request.pdk.processID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.pdk.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.pdk.digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(diagnostic(severity: .error, code: "pdk_provenance_missing", message: "PDK process, version and digest are required.", actions: ["provide_pdk_provenance"]))
        }
        if request.inputLayout == nil && request.initialSnapshot == nil {
            diagnostics.append(diagnostic(severity: .error, code: "physical_snapshot_missing", message: "A canonical physical snapshot is required; native execution does not infer placement state from UI or opaque netlist files.", actions: ["provide_initial_snapshot", "provide_input_layout_reference"]))
        }
        if request.inputLayout != nil && request.initialSnapshot != nil {
            diagnostics.append(diagnostic(severity: .error, code: "ambiguous_input_state", message: "Provide either inputLayout or initialSnapshot, not both.", actions: ["choose_one_canonical_input_state"]))
        }
        if let inputLayout = request.inputLayout, inputLayout.layoutArtifact.format != .json && inputLayout.layoutArtifact.format != .def {
            diagnostics.append(diagnostic(severity: .error, code: "unsupported_layout_format", message: "The native backend accepts canonical JSON and the supported DEF subset; \(inputLayout.layoutArtifact.format.rawValue) requires an external adapter.", actions: ["convert_to_canonical_json_or_def", "use_a_qualified_external_adapter"]))
        }
        let references = request.inputs + [request.design.artifact, request.constraints.artifact, request.pdk.manifest]
        for reference in references where reference.path.hasPrefix("/") {
            diagnostics.append(diagnostic(severity: .error, code: "absolute_artifact_path", message: "Artifact paths must be project-relative: \(reference.path)", entity: reference.path, actions: ["use_project_relative_artifact_paths"]))
        }
        return diagnostics
    }

    private var emptyPayload: PhysicalDesignPayload {
        PhysicalDesignPayload(physicalDesign: nil, changedObjectCount: 0, candidateActions: [])
    }

    private func changedObjectCount(before: PhysicalDesignSnapshot, after: PhysicalDesignSnapshot) -> Int {
        var count = 0
        if before.die != after.die { count += 1 }
        if before.core != after.core { count += 1 }
        if before.rows != after.rows { count += max(before.rows.count, after.rows.count) }
        if before.cells != after.cells { count += max(before.cells.count, after.cells.count) }
        if before.nets != after.nets { count += max(before.nets.count, after.nets.count) }
        if before.powerStructures != after.powerStructures { count += max(before.powerStructures.count, after.powerStructures.count) }
        if before.clockTrees != after.clockTrees { count += max(before.clockTrees.count, after.clockTrees.count) }
        if before.routes != after.routes { count += max(before.routes.count, after.routes.count) }
        if before.vias != after.vias { count += max(before.vias.count, after.vias.count) }
        if before.fills != after.fills { count += max(before.fills.count, after.fills.count) }
        if before.hotspots != after.hotspots { count += max(before.hotspots.count, after.hotspots.count) }
        if before.antennaRepairs != after.antennaRepairs { count += max(before.antennaRepairs.count, after.antennaRepairs.count) }
        return count
    }

    private func envelope(
        request: PhysicalDesignRequest,
        status: XcircuiteEngineExecutionStatus,
        diagnostics: [XcircuiteEngineDiagnostic],
        payload: PhysicalDesignPayload,
        artifacts: [XcircuiteFileReference] = [],
        startedAt: Date,
        seed: UInt64? = nil
    ) -> XcircuiteEngineResultEnvelope<PhysicalDesignPayload> {
        XcircuiteEngineResultEnvelope(
            schemaVersion: PhysicalDesignRequest.currentSchemaVersion,
            runID: request.runID,
            status: status,
            diagnostics: diagnostics,
            artifacts: artifacts,
            metadata: XcircuiteEngineExecutionMetadata(
                engineID: request.stage.engineID,
                implementationID: implementationID,
                implementationVersion: implementationVersion,
                startedAt: startedAt,
                completedAt: Date(),
                seed: seed
            ),
            payload: payload
        )
    }

    private func diagnostic(
        severity: XcircuiteEngineDiagnosticSeverity,
        code: String,
        message: String,
        entity: String? = nil,
        actions: [String]
    ) -> XcircuiteEngineDiagnostic {
        XcircuiteEngineDiagnostic(severity: severity, code: code, message: message, entity: entity, suggestedActions: actions)
    }

    private func defDiagnostic(_ diagnostic: PhysicalDesignDEFDiagnostic) -> XcircuiteEngineDiagnostic {
        let location = "DEF:\(diagnostic.section):\(diagnostic.line)"
        let entity = diagnostic.entity.map { "\(location)/\($0)" } ?? location
        return XcircuiteEngineDiagnostic(
            severity: diagnostic.severity,
            code: diagnostic.code,
            message: "\(diagnostic.message) [\(location)]",
            entity: entity,
            suggestedActions: diagnostic.suggestedActions
        )
    }

    private struct LoadedSnapshot: Sendable {
        var snapshot: PhysicalDesignSnapshot
        var baseReference: PhysicalDesignReference?
        var sourceLayoutFormat: XcircuiteFileFormat?
        var sourceLayoutDigest: String?
        var sourceParserID: String?
        var sourceParserVersion: String?
        var sourceDiagnostics: [PhysicalDesignDEFDiagnostic]
    }
}
