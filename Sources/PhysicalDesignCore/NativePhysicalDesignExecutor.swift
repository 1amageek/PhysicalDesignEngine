import Foundation
import LogicIR
import CircuiteFoundation

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
    private let hasher: SHA256ContentDigester
    private let timingModelLoader: any PhysicalDesignClockTimingModelLoading

    public init(
        expectedStage: PhysicalDesignStage? = nil,
        allowedStages: Set<PhysicalDesignStage>? = nil,
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-native",
        implementationVersion: String = "1.0.0",
        timingModelLoader: any PhysicalDesignClockTimingModelLoading = LocalPhysicalDesignClockTimingModelLoader()
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
        self.hasher = SHA256ContentDigester()
        self.timingModelLoader = timingModelLoader
    }

    public func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignResult {
        let startedAt = Date()
        if let allowedStages, !allowedStages.contains(request.stage) {
            let expectedStage = allowedStages.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ", ")
            return try envelope(
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
            return try envelope(
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
            let timingModel = try await loadClockTimingModel(from: request)
            try Task.checkCancellation()
            let outcome = await mutationEngine.apply(
                request,
                to: loaded.snapshot,
                clockTimingModel: timingModel,
                clockTimingModelReference: request.clockTimingModel
            )
            switch outcome.status {
            case .blocked, .cancelled:
                return try envelope(
                    request: request,
                    status: outcome.status,
                    diagnostics: outcome.diagnostics,
                    payload: PhysicalDesignPayload(
                        physicalDesign: request.inputLayout,
                        changedObjectCount: 0,
                        candidateActions: outcome.candidateActions,
                        metrics: outcome.metrics,
                        claims: outcome.claims
                    ),
                    startedAt: startedAt,
                    seed: request.configuration.deterministicSeed
                )
            case .failed:
                return try envelope(
                    request: request,
                    status: .failed,
                    diagnostics: outcome.diagnostics,
                    payload: emptyPayload,
                    startedAt: startedAt,
                    seed: request.configuration.deterministicSeed
                )
            case .completed:
                guard let output = outcome.snapshot else {
                    return try envelope(
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
            return try envelope(
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
            return try envelope(
                request: request,
                status: .blocked,
                diagnostics: error.diagnostics.map(defDiagnostic),
                payload: emptyPayload,
                startedAt: startedAt,
                seed: request.configuration.deterministicSeed
            )
        } catch let error as PhysicalDesignClockTimingModelError {
            return try envelope(
                request: request,
                status: .blocked,
                diagnostics: [diagnostic(
                    severity: .error,
                    code: "clock_timing_model_invalid",
                    message: error.localizedDescription,
                    actions: ["repair_clock_timing_model_and_source_artifacts"]
                )],
                payload: emptyPayload,
                startedAt: startedAt,
                seed: request.configuration.deterministicSeed
            )
        } catch let error as PhysicalDesignStoreError {
            let isInputFailure: Bool
            switch error {
            case .invalidPath, .readFailed:
                isInputFailure = true
            case .pathAlreadyExists, .writeFailed:
                isInputFailure = false
            }
            return try envelope(
                request: request,
                status: isInputFailure ? .blocked : .failed,
                diagnostics: [diagnostic(
                    severity: .error,
                    code: isInputFailure ? "physical_input_artifact_invalid" : "physical_artifact_persistence_failed",
                    message: error.localizedDescription,
                    actions: isInputFailure
                        ? ["repair_input_layout_artifact_and_integrity_metadata"]
                        : ["inspect_artifact_store_and_retry_with_a_new_run_id"]
                )],
                payload: emptyPayload,
                startedAt: startedAt,
                seed: request.configuration.deterministicSeed
            )
        } catch {
            return try envelope(
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

    private func loadClockTimingModel(
        from request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignClockTimingModel? {
        guard let reference = request.clockTimingModel else { return nil }
        guard reference.processID == request.pdk.processID,
              reference.pdkVersion == request.pdk.version,
              reference.pdkManifestArtifact == request.pdk.manifest else {
            throw PhysicalDesignClockTimingModelError.sourceArtifactMismatch("selected PDK")
        }
        return try await timingModelLoader.load(reference, from: artifactStore)
    }

    private func loadSnapshot(from request: PhysicalDesignRequest) async throws -> LoadedSnapshot {
        if request.inputLayout != nil && request.initialSnapshot != nil {
            throw PhysicalDesignStoreError.readFailed("request contains both inputLayout and initialSnapshot")
        }
        if let reference = request.inputLayout {
            guard reference.layoutArtifact.format == .json || reference.layoutArtifact.format == .def else {
                throw PhysicalDesignStoreError.readFailed("native backend accepts canonical JSON or supported DEF layout artifacts only")
            }
            let expectedArtifactDigest = reference.layoutArtifact.digest.hexadecimalValue
            let expectedArtifactByteCount = reference.layoutArtifact.byteCount
            guard !expectedArtifactDigest.isEmpty,
                  !reference.layoutDigest.isEmpty else {
                throw PhysicalDesignStoreError.readFailed(
                    "input layout reference lacks complete integrity metadata"
                )
            }
            let data = try await artifactStore.read(reference.layoutArtifact)
            guard UInt64(data.count) == expectedArtifactByteCount else {
                throw PhysicalDesignStoreError.readFailed("input layout byte count does not match the physical design reference")
            }
            let sourceDigest = try hasher.digest(data: data, using: .sha256).hexadecimalValue
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
            guard expectedArtifactDigest == sourceDigest, reference.layoutDigest == sourceDigest else {
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
    ) async throws -> PhysicalDesignResult {
        let snapshotData = try codec.encode(output)
        let snapshotPath = "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/revision.json"
        let snapshotReference = try await artifactStore.write(
            snapshotData,
            relativePath: snapshotPath,
            kind: .layout,
            format: .json,
            runID: request.runID
        )
        try await verifyWrittenArtifact(snapshotReference, expectedData: snapshotData)

        let defData = Data(defWriter.write(output).utf8)
        let defPath = "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/revision.def"
        let defReference = try await artifactStore.write(
            defData,
            relativePath: defPath,
            kind: .layout,
            format: .def,
            runID: request.runID
        )
        try await verifyWrittenArtifact(defReference, expectedData: defData)

        let physicalReference = PhysicalDesignReference(
            layoutArtifact: snapshotReference,
            topCell: output.topCell,
            layoutDigest: snapshotReference.digest.hexadecimalValue
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
        try await verifyWrittenArtifact(diffReference, expectedData: diffData)

        let completedAt = Date()
        let manifest = PhysicalDesignRunManifest(
            runID: request.runID,
            stage: request.stage,
            status: .completed,
            design: request.design,
            constraints: request.constraints,
            requestedModeIDs: request.requestedModeIDs,
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
            sourceParserVersion: source.sourceParserVersion,
            implementationConfiguration: request.configuration,
            executionIntent: request.executionIntent,
            clockTimingModel: request.clockTimingModel,
            claims: outcome.claims
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
        try await verifyWrittenArtifact(manifestReference, expectedData: manifestData)

        let changedObjectCount = changedObjectCount(before: before, after: output)
        let payload = PhysicalDesignPayload(
            physicalDesign: physicalReference,
            changedObjectCount: changedObjectCount,
            candidateActions: outcome.candidateActions,
            designDiff: diffReference,
            metrics: outcome.metrics,
            runManifest: manifestReference,
            claims: outcome.claims
        )
        return try envelope(
            request: request,
            status: .completed,
            diagnostics: source.sourceDiagnostics.map(defDiagnostic) + outcome.diagnostics,
            payload: payload,
            artifacts: [snapshotReference, defReference, diffReference, manifestReference],
            startedAt: startedAt,
            seed: request.configuration.deterministicSeed
        )
    }

    private func validate(_ request: PhysicalDesignRequest) -> [DesignDiagnostic] {
        var diagnostics: [DesignDiagnostic] = []
        if request.schemaVersion != PhysicalDesignRequest.currentSchemaVersion {
            diagnostics.append(diagnostic(severity: .error, code: "unsupported_request_schema", message: "Request schema version \(request.schemaVersion) is not supported.", actions: ["upgrade_the_request_schema"]))
        }
        if request.executionIntent == .productionImplementation {
            diagnostics.append(diagnostic(
                severity: .error,
                code: "native_production_implementation_unsupported",
                message: "The native geometry backend cannot execute a production physical implementation request.",
                actions: ["configure_the_openroad_backend", "provide_exact_pdk_and_tool_artifacts"]
            ))
        }
        if request.executionIntent == .characterizedTiming {
            if request.stage != .clockTreeSynthesis {
                diagnostics.append(diagnostic(
                    severity: .error,
                    code: "native_characterized_timing_stage_unsupported",
                    message: "The native backend supports characterized timing only for its CTS geometry; placement and routing remain geometry smoke capabilities.",
                    actions: ["select_geometry_smoke", "use_a_qualified_timing_driven_backend"]
                ))
            }
            if request.clockTimingModel == nil {
                diagnostics.append(diagnostic(
                    severity: .error,
                    code: "clock_timing_model_required",
                    message: "Characterized CTS requires a PDK/RC/cell/corner-bound clock timing model.",
                    actions: ["provide_clock_timing_model"]
                ))
            }
        }
        if let timingReference = request.clockTimingModel {
            let timingArtifacts = [timingReference.modelArtifact] + timingReference.sourceArtifacts
            if !Set(timingArtifacts).isSubset(of: Set(request.inputs)) {
                diagnostics.append(diagnostic(
                    severity: .error,
                    code: "clock_timing_inputs_missing",
                    message: "Every timing characterization artifact must be retained in request inputs.",
                    actions: ["add_timing_model_pdk_rc_and_cell_library_to_inputs"]
                ))
            }
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
        let provenanceIssues = LogicDesignProvenanceValidation.issues(for: request.design)
            .filter { $0.code != "design_digest_missing" }
        diagnostics.append(contentsOf: provenanceIssues.map {
            diagnostic(
                severity: .error,
                code: $0.diagnosticCode,
                message: $0.message,
                actions: ["repair_design_provenance", "recreate_design_handoff"]
            )
        })
        if request.requestedModeIDs.isEmpty {
            diagnostics.append(diagnostic(
                severity: .error,
                code: "timing_mode_missing",
                message: "At least one timing mode is required for physical implementation.",
                actions: ["declare_timing_modes"]
            ))
        }
        if request.constraints.kind != .constraint {
            diagnostics.append(diagnostic(
                severity: .error,
                code: "physical_constraints_artifact_invalid",
                message: "Physical implementation constraints must be represented by a constraint artifact.",
                actions: ["provide_a_constraint_artifact"]
            ))
        }
        if request.constraints.format != .sdc {
            diagnostics.append(diagnostic(
                severity: .error,
                code: "physical_constraints_format_invalid",
                message: "Physical implementation constraints must use the SDC format.",
                actions: ["provide_sdc_constraints"]
            ))
        }
        let normalizedModeIDs = request.requestedModeIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalizedModeIDs.contains(where: \.isEmpty) {
            diagnostics.append(diagnostic(
                severity: .error,
                code: "timing_mode_id_invalid",
                message: "Timing mode identifiers must not be blank.",
                actions: ["repair_timing_mode_ids"]
            ))
        }
        if Set(normalizedModeIDs).count != normalizedModeIDs.count {
            diagnostics.append(diagnostic(
                severity: .error,
                code: "timing_mode_id_duplicate",
                message: "Timing mode identifiers must be unique.",
                actions: ["deduplicate_timing_mode_ids"]
            ))
        }
        let requiredInputs = [request.design.artifact, request.constraints, request.pdk.manifest]
            + (request.inputLayout.map { [$0.layoutArtifact] } ?? [])
        if !Set(requiredInputs).isSubset(of: Set(request.inputs)) {
            diagnostics.append(diagnostic(
                severity: .error,
                code: "physical_design_inputs_incomplete",
                message: "Design, constraints, PDK, and referenced input layout artifacts must be retained in request inputs.",
                actions: ["retain_all_physical_design_prerequisites"]
            ))
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
            diagnostics.append(diagnostic(severity: .error, code: "unsupported_layout_format", message: "The native backend accepts canonical JSON and the supported DEF subset; \(inputLayout.layoutArtifact.format.rawValue) requires a dedicated foreign-format decoder.", actions: ["convert_to_canonical_json_or_def", "use_a_qualified_mask_data_decoder"]))
        }
        if let inputLayout = request.inputLayout {
            diagnostics.append(contentsOf: inputLayout.validationDiagnostics().map {
                diagnostic(
                    severity: .error,
                    code: "physical_design_reference_invalid",
                    message: $0,
                    actions: ["repair_input_layout_reference"]
                )
            })
        }
        let artifactReferences = request.inputs + [request.design.artifact, request.constraints, request.pdk.manifest]
        for reference in artifactReferences where reference.path.hasPrefix("/") {
            diagnostics.append(diagnostic(severity: .error, code: "absolute_artifact_path", message: "Artifact paths must be project-relative: \(reference.path)", entity: reference.path, actions: ["use_project_relative_artifact_paths"]))
        }
        return diagnostics
    }

    private func verifyWrittenArtifact(
        _ reference: ArtifactReference,
        expectedData: Data
    ) async throws {
        guard reference.byteCount == UInt64(expectedData.count) else {
            throw PhysicalDesignStoreError.writeFailed("artifact \(reference.path) returned an invalid byte count")
        }
        let expectedDigest = try hasher.digest(data: expectedData, using: reference.digest.algorithm).hexadecimalValue
        guard reference.digest.algorithm == .sha256,
              reference.digest.hexadecimalValue == expectedDigest else {
            throw PhysicalDesignStoreError.writeFailed("artifact \(reference.path) returned an invalid SHA-256 digest")
        }
        let persistedData = try await artifactStore.read(reference)
        guard persistedData == expectedData else {
            throw PhysicalDesignStoreError.writeFailed("artifact \(reference.path) could not be re-read with identical bytes")
        }
    }

    private var emptyPayload: PhysicalDesignPayload {
        PhysicalDesignPayload(
            physicalDesign: nil,
            changedObjectCount: 0,
            candidateActions: [],
            claims: .blocked
        )
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
        if before.implementationState != after.implementationState { count += 1 }
        return count
    }

    private func envelope(
        request: PhysicalDesignRequest,
        status: PhysicalDesignExecutionStatus,
        diagnostics: [DesignDiagnostic],
        payload: PhysicalDesignPayload,
        artifacts: [ArtifactReference] = [],
        startedAt: Date,
        seed: UInt64? = nil
    ) throws -> PhysicalDesignResult {
        let configurationData = try codec.encode(request.configuration)
        let configurationDigest = try hasher.digest(data: configurationData, using: .sha256)
        let designRevision = try ContentDigest(
            algorithm: .sha256,
            hexadecimalValue: request.design.designDigest
        )
        let producer = try ProducerIdentity(
            kind: .engine,
            identifier: implementationID,
            version: implementationVersion
        )
        return PhysicalDesignResult(
            schemaVersion: PhysicalDesignRequest.currentSchemaVersion,
            runID: request.runID,
            status: status,
            diagnostics: diagnostics,
            artifacts: artifacts,
            provenance: try ExecutionProvenance(
                producer: producer,
                inputs: request.inputs,
                invocation: try ExecutionInvocation.inProcess(entryPoint: implementationID),
                configurationDigest: configurationDigest,
                designRevision: designRevision,
                randomSeed: seed,
                startedAt: startedAt,
                completedAt: Date()
            ),
            payload: payload
        )
    }

    private func diagnostic(
        severity: DiagnosticSeverity,
        code: String,
        message: String,
        entity: String? = nil,
        actions: [String]
    ) -> DesignDiagnostic {
        DesignDiagnostic(severity: severity, code: code, message: message, entity: entity, suggestedActions: actions)
    }

    private func defDiagnostic(_ diagnostic: PhysicalDesignDEFDiagnostic) -> DesignDiagnostic {
        let location = "DEF:\(diagnostic.section):\(diagnostic.line)"
        let entity = diagnostic.entity.map { "\(location)/\($0)" } ?? location
        return DesignDiagnostic(
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
        var sourceLayoutFormat: ArtifactFormat?
        var sourceLayoutDigest: String?
        var sourceParserID: String?
        var sourceParserVersion: String?
        var sourceDiagnostics: [PhysicalDesignDEFDiagnostic]
    }
}
