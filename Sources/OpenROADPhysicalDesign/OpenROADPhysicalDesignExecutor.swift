import CircuiteFoundation
import Foundation
import PhysicalDesignCore
import SignoffToolSupport

public struct OpenROADPhysicalDesignExecutor: PhysicalDesignStageExecuting {
    public let artifactStore: any PhysicalDesignArtifactStore
    public let implementationID: String
    public let implementationVersion: String

    private let processRunner: (any TimedProcessRunning)?
    private let scratchRoot: URL
    private let codec = PhysicalDesignJSONCodec()
    private let defParser = PhysicalDesignDEFParser()
    private let defWriter = PhysicalDesignDEFWriter()
    private let diffBuilder = PhysicalDesignDiffBuilder()
    private let hasher = SHA256ContentDigester()

    public init(
        artifactStore: any PhysicalDesignArtifactStore,
        implementationID: String = "physical-design-openroad",
        implementationVersion: String = "1.0.0",
        processRunner: (any TimedProcessRunning)? = nil,
        scratchRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.artifactStore = artifactStore
        self.implementationID = implementationID
        self.implementationVersion = implementationVersion
        self.processRunner = processRunner
        self.scratchRoot = scratchRoot.standardizedFileURL
    }

    public func execute(_ request: PhysicalDesignRequest) async throws -> PhysicalDesignResult {
        let startedAt = Date()
        guard request.executionIntent == .productionImplementation else {
            return try result(
                request: request,
                status: .blocked,
                diagnostics: [diagnostic(
                    code: "openroad_execution_intent_invalid",
                    message: "OpenROAD execution requires productionImplementation intent.",
                    actions: ["set_production_implementation_intent"]
                )],
                startedAt: startedAt
            )
        }
        guard let configuration = request.productionConfiguration else {
            return try result(
                request: request,
                status: .blocked,
                diagnostics: [diagnostic(
                    code: "openroad_configuration_missing",
                    message: OpenROADExecutionError.productionConfigurationMissing.localizedDescription,
                    actions: ["provide_openroad_configuration"]
                )],
                startedAt: startedAt
            )
        }
        guard configuration.backendID.lowercased() == "openroad" else {
            return try result(
                request: request,
                status: .blocked,
                diagnostics: [diagnostic(
                    code: "physical_design_backend_unsupported",
                    message: OpenROADExecutionError.unsupportedBackend(configuration.backendID).localizedDescription,
                    actions: ["select_openroad_backend"]
                )],
                startedAt: startedAt
            )
        }
        let requestDiagnostics = validate(request, configuration: configuration)
        guard requestDiagnostics.isEmpty else {
            return try result(
                request: request,
                status: .blocked,
                diagnostics: requestDiagnostics,
                startedAt: startedAt,
                configuration: configuration
            )
        }

        do {
            try Task.checkCancellation()
            let executableURL = try verifiedExecutable(configuration.executable)
            let workspace = try makeScratchWorkspace(runID: request.runID)
            let executionResult: PhysicalDesignResult
            do {
                executionResult = try await execute(
                    request,
                    configuration: configuration,
                    executableURL: executableURL,
                    workspace: workspace,
                    startedAt: startedAt
                )
            } catch {
                let cleanupError = cleanup(workspace: workspace)
                if let cleanupError {
                    throw OpenROADExecutionError.scratchWorkspaceFailed(
                        "\(error.localizedDescription); cleanup failed: \(cleanupError.localizedDescription)"
                    )
                }
                throw error
            }
            if let cleanupError = cleanup(workspace: workspace) {
                return try appendingCleanupWarning(
                    to: executionResult,
                    message: cleanupError.localizedDescription
                )
            }
            return executionResult
        } catch is CancellationError {
            return try result(
                request: request,
                status: .cancelled,
                diagnostics: [diagnostic(
                    severity: .warning,
                    code: "openroad_execution_cancelled",
                    message: "OpenROAD execution was cancelled and its process group was terminated.",
                    actions: ["resume_from_the_last_immutable_revision"]
                )],
                startedAt: startedAt,
                configuration: configuration
            )
        } catch let error as TimedProcessError {
            return try timedProcessFailure(
                error,
                request: request,
                configuration: configuration,
                startedAt: startedAt
            )
        } catch let error as OpenROADExecutionError {
            return try result(
                request: request,
                status: blockedError(error) ? .blocked : .failed,
                diagnostics: [diagnostic(
                    code: diagnosticCode(for: error),
                    message: error.localizedDescription,
                    actions: suggestedActions(for: error)
                )],
                startedAt: startedAt,
                configuration: configuration
            )
        } catch let error as PhysicalDesignStoreError {
            return try result(
                request: request,
                status: .blocked,
                diagnostics: [diagnostic(
                    code: "openroad_input_artifact_invalid",
                    message: error.localizedDescription,
                    actions: ["repair_artifact_integrity", "retain_all_production_inputs"]
                )],
                startedAt: startedAt,
                configuration: configuration
            )
        } catch {
            return try result(
                request: request,
                status: .failed,
                diagnostics: [diagnostic(
                    code: "openroad_execution_failed",
                    message: error.localizedDescription,
                    actions: ["inspect_openroad_process_configuration", "inspect_retained_artifacts"]
                )],
                startedAt: startedAt,
                configuration: configuration
            )
        }
    }

    private func execute(
        _ request: PhysicalDesignRequest,
        configuration: PhysicalDesignProductionConfiguration,
        executableURL: URL,
        workspace: ScratchWorkspace,
        startedAt: Date
    ) async throws -> PhysicalDesignResult {
        let before = try await loadInputSnapshot(request)
        try await materializeInputs(configuration, request: request, workspace: workspace, before: before)
        let generatedScript = generatedScriptText(request: request, configuration: configuration, hasInputDEF: before != nil)
        try Data(generatedScript.utf8).write(to: workspace.generatedScript, options: .atomic)
        let environment = try processEnvironment(workspace: workspace)
        let activeProcessRunner: any TimedProcessRunning = processRunner
            ?? TimedProcessRunner(timeoutSeconds: configuration.timeoutSeconds)

        let versionResult = try await activeProcessRunner.run(
            process: process(
                executableURL: executableURL,
                arguments: configuration.versionArguments,
                workspace: workspace,
                environment: environment.variables
            ),
            cancellationCheck: { Task.isCancelled }
        )
        guard versionResult.exitCode == 0 else {
            throw OpenROADExecutionError.toolVersionProbeFailed("exit status \(versionResult.exitCode)")
        }
        let observedVersion = [versionResult.standardOutput, versionResult.standardError]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !observedVersion.isEmpty else {
            throw OpenROADExecutionError.toolVersionProbeFailed("tool returned no version text")
        }
        guard observedVersion.contains(configuration.executable.expectedVersion) else {
            throw OpenROADExecutionError.toolVersionMismatch(
                expected: configuration.executable.expectedVersion,
                observed: observedVersion
            )
        }

        let arguments = ["-no_init", "-exit", workspace.generatedScript.path(percentEncoded: false)]
        let invocation = try ExecutionInvocation.externalProcess(
            executable: executableURL.path(percentEncoded: false),
            arguments: arguments,
            workingDirectory: workspace.root.path(percentEncoded: false)
        )
        let processResult: TimedProcessResult
        do {
            processResult = try await activeProcessRunner.run(
                process: process(
                    executableURL: executableURL,
                    arguments: arguments,
                    workspace: workspace,
                    environment: environment.variables
                ),
                cancellationCheck: { Task.isCancelled }
            )
        } catch let error as TimedProcessError {
            try verifyExecutable(configuration.executable, at: executableURL)
            let captured = capturedOutput(from: error)
            let streams = try await persistProcessStreams(
                request: request,
                generatedScript: Data(generatedScript.utf8),
                standardOutput: Data(captured.standardOutput.utf8),
                standardError: Data(captured.standardError.utf8)
            )
            let processEvidence = try await persistProcessEvidence(
                request: request,
                configuration: configuration,
                observedVersion: observedVersion,
                invocation: invocation,
                environment: environment.fingerprint,
                outputs: [],
                streams: streams,
                termination: termination(for: error),
                exitCode: nil,
                startedAt: startedAt
            )
            let failure = timedProcessStatusAndCode(for: error)
            return try result(
                request: request,
                status: failure.status,
                diagnostics: [diagnostic(
                    severity: failure.status == .cancelled ? .warning : .error,
                    code: failure.code,
                    message: error.localizedDescription,
                    actions: ["inspect_openroad_stdout", "inspect_openroad_stderr", "inspect_generated_openroad_script"]
                )],
                artifacts: streams.references + [processEvidence],
                startedAt: startedAt,
                configuration: configuration,
                invocation: invocation,
                environment: environment.fingerprint,
                supportingTool: configuration.executable
            )
        }
        try verifyExecutable(configuration.executable, at: executableURL)

        let evidenceArtifacts = try await persistProcessStreams(
            request: request,
            generatedScript: Data(generatedScript.utf8),
            standardOutput: Data(processResult.standardOutput.utf8),
            standardError: Data(processResult.standardError.utf8)
        )
        guard processResult.exitCode == 0 else {
            let processEvidence = try await persistProcessEvidence(
                request: request,
                configuration: configuration,
                observedVersion: observedVersion,
                invocation: invocation,
                environment: environment.fingerprint,
                outputs: [],
                streams: evidenceArtifacts,
                termination: .nonzeroExit,
                exitCode: processResult.exitCode,
                startedAt: startedAt
            )
            return try result(
                request: request,
                status: .failed,
                diagnostics: [diagnostic(
                    code: "openroad_nonzero_exit",
                    message: OpenROADExecutionError.processFailed(exitCode: processResult.exitCode).localizedDescription,
                    actions: ["inspect_openroad_stdout", "inspect_openroad_stderr", "inspect_generated_openroad_script"]
                )],
                artifacts: evidenceArtifacts.references + [processEvidence],
                startedAt: startedAt,
                configuration: configuration,
                invocation: invocation,
                environment: environment.fingerprint,
                supportingTool: configuration.executable
            )
        }

        guard FileManager.default.fileExists(atPath: workspace.outputDEF.path(percentEncoded: false)) else {
            throw OpenROADExecutionError.outputDEFUnavailable
        }
        let outputDEF = try Data(contentsOf: workspace.outputDEF, options: .mappedIfSafe)
        guard !outputDEF.isEmpty else {
            throw OpenROADExecutionError.outputDEFUnavailable
        }
        let outputDEFReference = try await writeVerified(
            outputDEF,
            path: artifactPath(request, name: "openroad-output.def"),
            kind: .layout,
            format: .def,
            runID: request.runID
        )
        let stageMetrics = try loadStageCompletionMetrics(
            from: workspace.stageCompletion,
            expectedStage: request.stage
        )
        let parseResult = defParser.parse(outputDEF)
        guard parseResult.isValid, let output = parseResult.snapshot else {
            let processEvidence = try await persistProcessEvidence(
                request: request,
                configuration: configuration,
                observedVersion: observedVersion,
                invocation: invocation,
                environment: environment.fingerprint,
                outputs: [outputDEFReference],
                streams: evidenceArtifacts,
                termination: .completed,
                exitCode: processResult.exitCode,
                startedAt: startedAt
            )
            return try result(
                request: request,
                status: .blocked,
                diagnostics: parseResult.diagnostics.map(defDiagnostic) + [diagnostic(
                    code: "openroad_output_def_unsupported",
                    message: OpenROADExecutionError.outputDEFInvalid.localizedDescription,
                    actions: ["extend_canonical_def_support", "inspect_openroad_output_def"]
                )],
                artifacts: evidenceArtifacts.references + [outputDEFReference, processEvidence],
                startedAt: startedAt,
                configuration: configuration,
                invocation: invocation,
                environment: environment.fingerprint,
                supportingTool: configuration.executable
            )
        }
        guard output.topCell == request.design.topDesignName else {
            throw OpenROADExecutionError.outputTopCellMismatch(
                expected: request.design.topDesignName,
                actual: output.topCell
            )
        }
        return try await persistCompletedResult(
            request: request,
            configuration: configuration,
            before: before,
            output: output,
            outputDEF: outputDEFReference,
            stageMetrics: stageMetrics,
            observedVersion: observedVersion,
            invocation: invocation,
            environment: environment.fingerprint,
            streams: evidenceArtifacts,
            startedAt: startedAt,
            sourceDiagnostics: parseResult.diagnostics
        )
    }

    private func persistCompletedResult(
        request: PhysicalDesignRequest,
        configuration: PhysicalDesignProductionConfiguration,
        before: PhysicalDesignSnapshot?,
        output: PhysicalDesignSnapshot,
        outputDEF: ArtifactReference,
        stageMetrics: [PhysicalDesignMetric],
        observedVersion: String,
        invocation: ExecutionInvocation,
        environment: ExecutionEnvironmentFingerprint,
        streams: ProcessStreamArtifacts,
        startedAt: Date,
        sourceDiagnostics: [PhysicalDesignDEFDiagnostic]
    ) async throws -> PhysicalDesignResult {
        let revisionData = try codec.encode(output)
        let revision = try await writeVerified(
            revisionData,
            path: artifactPath(request, name: "revision.json"),
            kind: .layout,
            format: .json,
            runID: request.runID
        )
        let physicalReference = PhysicalDesignReference(
            layoutArtifact: revision,
            topCell: output.topCell,
            layoutDigest: revision.digest.hexadecimalValue
        )
        let diff = try diffBuilder.build(
            runID: request.runID,
            stage: request.stage,
            actor: implementationID,
            before: before,
            after: output,
            baseSnapshot: request.inputLayout?.layoutArtifact,
            proposedSnapshot: revision
        )
        let diffReference = try await writeVerified(
            codec.encode(diff),
            path: artifactPath(request, name: "design-diff.json"),
            kind: .designDiff,
            format: .json,
            runID: request.runID
        )
        let stageCompletion = PhysicalDesignStageCompletionEvidence(
            runID: request.runID,
            stage: request.stage,
            outputLayout: revision,
            metrics: stageMetrics,
            completedAt: Date()
        )
        guard stageCompletion.isValid else {
            throw OpenROADExecutionError.stageCompletionEvidenceInvalid(
                "required metrics are missing, duplicated, or non-finite"
            )
        }
        let stageCompletionReference = try await writeVerified(
            codec.encode(stageCompletion),
            path: artifactPath(request, name: "stage-completion.json"),
            kind: .evidence,
            format: .json,
            runID: request.runID
        )
        let processEvidence = try await persistProcessEvidence(
            request: request,
            configuration: configuration,
            observedVersion: observedVersion,
            invocation: invocation,
            environment: environment,
            outputs: [outputDEF, stageCompletionReference],
            streams: streams,
            termination: .completed,
            exitCode: 0,
            startedAt: startedAt
        )
        let claims = PhysicalDesignCapabilityClaims(
            geometry: .verified,
            timing: .blocked,
            production: .blocked
        )
        let manifestArtifacts = streams.references
            + [outputDEF, revision, diffReference, stageCompletionReference, processEvidence]
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
            artifacts: manifestArtifacts,
            implementationID: implementationID,
            implementationVersion: implementationVersion,
            deterministicSeed: request.configuration.deterministicSeed,
            createdAt: startedAt,
            completedAt: Date(),
            sourceLayoutFormat: .def,
            sourceLayoutDigest: outputDEF.digest.hexadecimalValue,
            sourceParserID: PhysicalDesignDEFParser.parserID,
            sourceParserVersion: PhysicalDesignDEFParser.parserVersion,
            implementationConfiguration: request.configuration,
            executionIntent: request.executionIntent,
            clockTimingModel: request.clockTimingModel,
            productionConfiguration: configuration,
            processEvidence: processEvidence,
            claims: claims
        )
        let manifestDiagnostics = manifest.validationDiagnostics()
        guard manifestDiagnostics.isEmpty else {
            throw PhysicalDesignStoreError.writeFailed(
                "OpenROAD run manifest validation failed: \(manifestDiagnostics.joined(separator: "; "))"
            )
        }
        let manifestReference = try await writeVerified(
            codec.encode(manifest),
            path: artifactPath(request, name: "run-manifest.json"),
            kind: .report,
            format: .json,
            runID: request.runID
        )
        let payload = PhysicalDesignPayload(
            physicalDesign: physicalReference,
            changedObjectCount: changedObjectCount(before: before, after: output),
            candidateActions: ["run_independent_physical_oracle", "qualify_openroad_process_evidence"],
            designDiff: diffReference,
            metrics: stageMetrics,
            runManifest: manifestReference,
            stageCompletionEvidence: stageCompletionReference,
            claims: claims
        )
        return try result(
            request: request,
            status: .completed,
            diagnostics: sourceDiagnostics.map(defDiagnostic) + [diagnostic(
                severity: .information,
                code: "openroad_execution_requires_independent_qualification",
                message: "OpenROAD produced a canonical DEF revision, but production eligibility remains blocked until ToolQualification and flow policy accept independent evidence.",
                actions: ["run_independent_physical_oracle", "evaluate_tool_qualification"]
            )],
            payload: payload,
            artifacts: manifestArtifacts + [manifestReference],
            startedAt: startedAt,
            configuration: configuration,
            invocation: invocation,
            environment: environment,
            supportingTool: configuration.executable
        )
    }

    private func persistProcessStreams(
        request: PhysicalDesignRequest,
        generatedScript: Data,
        standardOutput: Data,
        standardError: Data
    ) async throws -> ProcessStreamArtifacts {
        let script = try await writeVerified(
            generatedScript,
            path: artifactPath(request, name: "openroad-generated.tcl"),
            kind: .evidence,
            format: .text,
            runID: request.runID
        )
        let stdout = try await writeVerified(
            standardOutput,
            path: artifactPath(request, name: "openroad-stdout.log"),
            kind: .log,
            format: .text,
            runID: request.runID
        )
        let stderr = try await writeVerified(
            standardError,
            path: artifactPath(request, name: "openroad-stderr.log"),
            kind: .log,
            format: .text,
            runID: request.runID
        )
        return ProcessStreamArtifacts(script: script, stdout: stdout, stderr: stderr)
    }

    private func persistProcessEvidence(
        request: PhysicalDesignRequest,
        configuration: PhysicalDesignProductionConfiguration,
        observedVersion: String,
        invocation: ExecutionInvocation,
        environment: ExecutionEnvironmentFingerprint,
        outputs: [ArtifactReference],
        streams: ProcessStreamArtifacts,
        termination: PhysicalDesignProcessTermination,
        exitCode: Int32?,
        startedAt: Date
    ) async throws -> ArtifactReference {
        let evidence = PhysicalDesignProcessEvidence(
            runID: request.runID,
            stage: request.stage,
            backendID: configuration.backendID,
            executable: configuration.executable,
            observedVersion: observedVersion,
            invocation: invocation,
            environment: environment,
            inputs: request.inputs,
            outputs: outputs,
            standardOutput: streams.stdout,
            standardError: streams.stderr,
            generatedScript: streams.script,
            termination: termination,
            exitCode: exitCode,
            startedAt: startedAt,
            completedAt: Date()
        )
        return try await writeVerified(
            codec.encode(evidence),
            path: artifactPath(request, name: "process-evidence.json"),
            kind: .evidence,
            format: .json,
            runID: request.runID
        )
    }

    private func materializeInputs(
        _ configuration: PhysicalDesignProductionConfiguration,
        request: PhysicalDesignRequest,
        workspace: ScratchWorkspace,
        before: PhysicalDesignSnapshot?
    ) async throws {
        for (index, reference) in configuration.technologyLEFs.enumerated() {
            try await materialize(reference, at: workspace.inputs.appending(path: "technology-\(index).lef"))
        }
        for (index, reference) in configuration.cellLEFs.enumerated() {
            try await materialize(reference, at: workspace.inputs.appending(path: "cells-\(index).lef"))
        }
        for (index, reference) in configuration.libertyLibraries.enumerated() {
            try await materialize(reference, at: workspace.inputs.appending(path: "library-\(index).lib"))
        }
        try await materialize(configuration.synthesizedNetlist, at: workspace.inputs.appending(path: "design.v"))
        try await materialize(configuration.rcSetupScript, at: workspace.inputs.appending(path: "rc-setup.tcl"))
        try await materialize(configuration.stageScript, at: workspace.inputs.appending(path: "stage.tcl"))
        try await materialize(request.design.artifact, at: workspace.inputs.appending(path: "design-ir.json"))
        try await materialize(request.constraints, at: workspace.inputs.appending(path: "constraints.sdc"))
        try await materialize(request.pdk.manifest, at: workspace.inputs.appending(path: "pdk.json"))
        if let before {
            try Data(defWriter.write(before).utf8).write(
                to: workspace.inputs.appending(path: "input.def"),
                options: .atomic
            )
        }
    }

    private func materialize(_ reference: ArtifactReference, at url: URL) async throws {
        // External EDA tools require owned filesystem paths. This copy is the
        // explicit process boundary; intermediate in-memory copies are avoided.
        let data = try await artifactStore.read(reference)
        guard UInt64(data.count) == reference.byteCount else {
            throw OpenROADExecutionError.inputArtifactInvalid("byte count mismatch at \(reference.path)")
        }
        let digest = try hasher.digest(data: data, using: .sha256)
        guard digest == reference.digest else {
            throw OpenROADExecutionError.inputArtifactInvalid("SHA-256 mismatch at \(reference.path)")
        }
        try data.write(to: url, options: .atomic)
    }

    private func loadInputSnapshot(_ request: PhysicalDesignRequest) async throws -> PhysicalDesignSnapshot? {
        if let initialSnapshot = request.initialSnapshot {
            return initialSnapshot
        }
        guard let inputLayout = request.inputLayout else {
            return nil
        }
        let data = try await artifactStore.read(inputLayout.layoutArtifact)
        let snapshot: PhysicalDesignSnapshot
        switch inputLayout.layoutArtifact.format {
        case .json:
            snapshot = try codec.decode(PhysicalDesignSnapshot.self, from: data)
        case .def:
            let result = defParser.parse(data)
            guard result.isValid, let parsed = result.snapshot else {
                throw OpenROADExecutionError.inputArtifactInvalid("input DEF is outside the canonical supported subset")
            }
            snapshot = parsed
        default:
            throw OpenROADExecutionError.inputArtifactInvalid("input layout must be canonical JSON or DEF")
        }
        guard snapshot.topCell == inputLayout.topCell,
              inputLayout.layoutDigest == inputLayout.layoutArtifact.digest.hexadecimalValue else {
            throw OpenROADExecutionError.inputArtifactInvalid("input layout identity mismatch")
        }
        return snapshot
    }

    private func generatedScriptText(
        request: PhysicalDesignRequest,
        configuration: PhysicalDesignProductionConfiguration,
        hasInputDEF: Bool
    ) -> String {
        var lines = [
            "set ::xcircuite_stage \(tclString(request.stage.rawValue))",
            "set ::xcircuite_corner \(tclString(configuration.cornerID))",
            "set ::xcircuite_process \(tclString(request.pdk.processID))",
            "set ::xcircuite_pdk_version \(tclString(request.pdk.version))",
            "set ::xcircuite_requested_modes [list \(request.requestedModeIDs.map(tclString).joined(separator: " "))]",
            "set ::xcircuite_output_def [file join [pwd] output.def]",
        ]
        for index in configuration.technologyLEFs.indices {
            lines.append("read_lef [file join [pwd] inputs technology-\(index).lef]")
        }
        for index in configuration.cellLEFs.indices {
            lines.append("read_lef [file join [pwd] inputs cells-\(index).lef]")
        }
        for index in configuration.libertyLibraries.indices {
            lines.append("read_liberty [file join [pwd] inputs library-\(index).lib]")
        }
        lines.append("read_verilog [file join [pwd] inputs design.v]")
        lines.append("link_design \(tclString(request.design.topDesignName))")
        if hasInputDEF {
            lines.append("read_def [file join [pwd] inputs input.def]")
        }
        lines.append("read_sdc [file join [pwd] inputs constraints.sdc]")
        lines.append("source [file join [pwd] inputs rc-setup.tcl]")
        lines.append("source [file join [pwd] inputs stage.tcl]")
        lines.append("if {![info exists ::xcircuite_completed_stage] || $::xcircuite_completed_stage ne $::xcircuite_stage} { error \"stage script did not attest the requested stage\" }")
        lines.append("if {![info exists ::xcircuite_stage_metrics]} { error \"stage script did not provide completion metrics\" }")
        lines.append("set ::xcircuite_stage_proof [open [file join [pwd] stage-completion.txt] w]")
        lines.append("puts $::xcircuite_stage_proof $::xcircuite_completed_stage")
        lines.append("dict for {key value} $::xcircuite_stage_metrics { puts $::xcircuite_stage_proof \"$key=$value\" }")
        lines.append("close $::xcircuite_stage_proof")
        lines.append("write_def $::xcircuite_output_def")
        lines.append("exit")
        return lines.joined(separator: "\n") + "\n"
    }

    private func processEnvironment(workspace: ScratchWorkspace) throws -> ProcessEnvironment {
        let variables = [
            "LC_ALL": "C",
            "LANG": "C",
            "TZ": "UTC",
            "HOME": workspace.home.path(percentEncoded: false),
            "TMPDIR": workspace.temporary.path(percentEncoded: false),
        ]
        let semanticEnvironment = "HOME=<isolated>\nLANG=C\nLC_ALL=C\nTMPDIR=<isolated>\nTZ=UTC\n"
        let digest = try hasher.digest(data: Data(semanticEnvironment.utf8), using: .sha256)
        let fingerprint = try ExecutionEnvironmentFingerprint(
            platform: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            toolchain: "openroad-external-process",
            environmentDigest: digest
        )
        return ProcessEnvironment(variables: variables, fingerprint: fingerprint)
    }

    private func process(
        executableURL: URL,
        arguments: [String],
        workspace: ScratchWorkspace,
        environment: [String: String]
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workspace.root
        process.environment = environment
        return process
    }

    private func verifiedExecutable(_ reference: PhysicalDesignExecutableReference) throws -> URL {
        let requestedURL = URL(filePath: reference.path).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: requestedURL.path(percentEncoded: false)) else {
            throw OpenROADExecutionError.executableUnavailable(reference.path)
        }
        let canonicalURL = requestedURL.resolvingSymlinksInPath()
        try verifyExecutable(reference, at: canonicalURL)
        return canonicalURL
    }

    private func verifyExecutable(
        _ reference: PhysicalDesignExecutableReference,
        at url: URL
    ) throws {
        let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resourceValues.isRegularFile == true else {
            throw OpenROADExecutionError.executableNotRegularFile(url.path(percentEncoded: false))
        }
        guard UInt64(resourceValues.fileSize ?? -1) == reference.byteCount else {
            throw OpenROADExecutionError.executableIntegrityMismatch("byte count changed")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = try hasher.digest(data: data, using: .sha256)
        guard digest == reference.digest else {
            throw OpenROADExecutionError.executableIntegrityMismatch("SHA-256 digest changed")
        }
    }

    private func makeScratchWorkspace(runID: String) throws -> ScratchWorkspace {
        let root = scratchRoot.appending(path: "physical-design-openroad-\(UUID().uuidString)", directoryHint: .isDirectory)
        let inputs = root.appending(path: "inputs", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "tmp", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        } catch {
            throw OpenROADExecutionError.scratchWorkspaceFailed(error.localizedDescription)
        }
        return ScratchWorkspace(
            root: root,
            inputs: inputs,
            home: home,
            temporary: temporary,
            generatedScript: root.appending(path: "run-openroad.tcl"),
            outputDEF: root.appending(path: "output.def"),
            stageCompletion: root.appending(path: "stage-completion.txt")
        )
    }

    private func loadStageCompletionMetrics(
        from url: URL,
        expectedStage: PhysicalDesignStage
    ) throws -> [PhysicalDesignMetric] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw OpenROADExecutionError.stageCompletionEvidenceInvalid(
                "stage-completion.txt was not produced"
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenROADExecutionError.stageCompletionEvidenceInvalid(
                "stage completion evidence is not UTF-8"
            )
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first == expectedStage.rawValue else {
            throw OpenROADExecutionError.stageCompletionEvidenceInvalid(
                "attested stage does not match \(expectedStage.rawValue)"
            )
        }
        var metrics: [PhysicalDesignMetric] = []
        var names = Set<String>()
        for line in lines.dropFirst() {
            let components = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard components.count == 2,
                  !components[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  names.insert(components[0]).inserted,
                  let value = Double(components[1]),
                  value.isFinite else {
                throw OpenROADExecutionError.stageCompletionEvidenceInvalid(
                    "metric lines must contain unique finite name=value pairs"
                )
            }
            metrics.append(PhysicalDesignMetric(name: components[0], value: value))
        }
        let required = Set(PhysicalDesignStageCompletionEvidence.requiredMetricNames(
            for: expectedStage
        ))
        guard required.isSubset(of: names) else {
            throw OpenROADExecutionError.stageCompletionEvidenceInvalid(
                "required metrics are missing: \(required.subtracting(names).sorted().joined(separator: ", "))"
            )
        }
        return metrics.sorted { $0.name < $1.name }
    }

    private func cleanup(workspace: ScratchWorkspace) -> (any Error)? {
        do {
            try FileManager.default.removeItem(at: workspace.root)
            return nil
        } catch {
            return error
        }
    }

    private func writeVerified(
        _ data: Data,
        path: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        runID: String
    ) async throws -> ArtifactReference {
        let reference = try await artifactStore.write(
            data,
            relativePath: path,
            kind: kind,
            format: format,
            runID: runID
        )
        let expectedDigest = try hasher.digest(data: data, using: .sha256)
        let persistedData = try await artifactStore.read(reference)
        guard reference.byteCount == UInt64(data.count),
              reference.digest.algorithm == .sha256,
              reference.digest == expectedDigest,
              persistedData == data else {
            throw PhysicalDesignStoreError.writeFailed("artifact verification failed: \(path)")
        }
        return reference
    }

    private func result(
        request: PhysicalDesignRequest,
        status: PhysicalDesignExecutionStatus,
        diagnostics: [DesignDiagnostic],
        payload: PhysicalDesignPayload? = nil,
        artifacts: [ArtifactReference] = [],
        startedAt: Date,
        configuration: PhysicalDesignProductionConfiguration? = nil,
        invocation: ExecutionInvocation? = nil,
        environment: ExecutionEnvironmentFingerprint? = nil,
        supportingTool: PhysicalDesignExecutableReference? = nil
    ) throws -> PhysicalDesignResult {
        let configurationData: Data
        if let configuration {
            configurationData = try codec.encode(configuration)
        } else {
            configurationData = try codec.encode(request.configuration)
        }
        let configurationDigest = try hasher.digest(data: configurationData, using: .sha256)
        let producer = try ProducerIdentity(
            kind: .engine,
            identifier: implementationID,
            version: implementationVersion
        )
        let supportingTools = try supportingTool.map {
            [try ProducerIdentity(
                kind: .tool,
                identifier: $0.toolID,
                version: $0.expectedVersion,
                build: $0.digest.hexadecimalValue
            )]
        } ?? []
        return PhysicalDesignResult(
            schemaVersion: PhysicalDesignRequest.currentSchemaVersion,
            runID: request.runID,
            status: status,
            diagnostics: diagnostics,
            artifacts: artifacts,
            provenance: try ExecutionProvenance(
                producer: producer,
                supportingTools: supportingTools,
                inputs: request.inputs,
                invocation: invocation ?? ExecutionInvocation.inProcess(entryPoint: implementationID),
                environment: environment,
                configurationDigest: configurationDigest,
                designRevision: try ContentDigest(
                    algorithm: .sha256,
                    hexadecimalValue: request.design.designDigest
                ),
                randomSeed: request.configuration.deterministicSeed,
                startedAt: startedAt,
                completedAt: Date()
            ),
            payload: payload ?? PhysicalDesignPayload(
                physicalDesign: nil,
                changedObjectCount: 0,
                candidateActions: [],
                claims: .blocked
            )
        )
    }

    private func timedProcessFailure(
        _ error: TimedProcessError,
        request: PhysicalDesignRequest,
        configuration: PhysicalDesignProductionConfiguration,
        startedAt: Date
    ) throws -> PhysicalDesignResult {
        let failure = timedProcessStatusAndCode(for: error)
        return try result(
            request: request,
            status: failure.status,
            diagnostics: [diagnostic(
                severity: failure.status == .cancelled ? .warning : .error,
                code: failure.code,
                message: error.localizedDescription,
                actions: ["inspect_openroad_process_configuration", "inspect_retained_process_evidence"]
            )],
            startedAt: startedAt,
            configuration: configuration
        )
    }

    private func timedProcessStatusAndCode(
        for error: TimedProcessError
    ) -> (status: PhysicalDesignExecutionStatus, code: String) {
        switch error {
        case .cancelled:
            return (.cancelled, "openroad_execution_cancelled")
        case .timedOut:
            return (.failed, "openroad_execution_timed_out")
        case .invalidConfiguration:
            return (.blocked, "openroad_process_configuration_invalid")
        case .launchFailed:
            return (.blocked, "openroad_launch_failed")
        case .cancellationCheckFailed:
            return (.failed, "openroad_cancellation_check_failed")
        }
    }

    private func termination(for error: TimedProcessError) -> PhysicalDesignProcessTermination {
        switch error {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .invalidConfiguration, .launchFailed:
            return .launchFailed
        case .cancellationCheckFailed:
            return .cancellationCheckFailed
        }
    }

    private func capturedOutput(
        from error: TimedProcessError
    ) -> (standardOutput: String, standardError: String) {
        switch error {
        case .cancelled(_, let standardOutput, let standardError),
             .timedOut(_, _, let standardOutput, let standardError),
             .cancellationCheckFailed(_, _, let standardOutput, let standardError):
            return (standardOutput, standardError)
        case .invalidConfiguration, .launchFailed:
            return ("", error.localizedDescription)
        }
    }

    private func appendingCleanupWarning(
        to value: PhysicalDesignResult,
        message: String
    ) throws -> PhysicalDesignResult {
        PhysicalDesignResult(
            schemaVersion: value.schemaVersion,
            runID: value.runID,
            status: value.status,
            diagnostics: value.diagnostics + [diagnostic(
                severity: .warning,
                code: "openroad_scratch_cleanup_failed",
                message: message,
                actions: ["remove_the_isolated_openroad_scratch_directory"]
            )],
            artifacts: value.artifacts,
            provenance: value.provenance,
            payload: value.payload
        )
    }

    private func diagnostic(
        severity: DiagnosticSeverity = .error,
        code: String,
        message: String,
        actions: [String]
    ) -> DesignDiagnostic {
        DesignDiagnostic(
            severity: severity,
            code: code,
            message: message,
            suggestedActions: actions
        )
    }

    private func defDiagnostic(_ value: PhysicalDesignDEFDiagnostic) -> DesignDiagnostic {
        DesignDiagnostic(
            severity: value.severity,
            code: value.code,
            message: value.message,
            entity: value.entity,
            suggestedActions: value.suggestedActions
        )
    }

    private func artifactPath(_ request: PhysicalDesignRequest, name: String) -> String {
        "runs/\(request.runID)/physical-design/\(request.stage.rawValue)/\(name)"
    }

    private func tclString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private func changedObjectCount(
        before: PhysicalDesignSnapshot?,
        after: PhysicalDesignSnapshot
    ) -> Int {
        guard let before else { return 1 }
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

    private func blockedError(_ error: OpenROADExecutionError) -> Bool {
        switch error {
        case .productionConfigurationMissing, .unsupportedBackend, .executableUnavailable,
             .executableNotRegularFile, .executableIntegrityMismatch, .toolVersionProbeFailed,
             .toolVersionMismatch, .inputArtifactInvalid, .outputDEFInvalid,
             .outputTopCellMismatch, .stageCompletionEvidenceInvalid:
            return true
        case .processFailed, .outputDEFUnavailable, .scratchWorkspaceFailed:
            return false
        }
    }

    private func validate(
        _ request: PhysicalDesignRequest,
        configuration: PhysicalDesignProductionConfiguration
    ) -> [DesignDiagnostic] {
        var diagnostics: [DesignDiagnostic] = []
        if request.schemaVersion != PhysicalDesignRequest.currentSchemaVersion {
            diagnostics.append(diagnostic(
                code: "unsupported_request_schema",
                message: "Physical design request schema is not supported.",
                actions: ["recreate_the_request_with_the_current_schema"]
            ))
        }
        if request.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(diagnostic(
                code: "run_id_missing",
                message: "A non-empty run ID is required.",
                actions: ["provide_a_run_id"]
            ))
        }
        if request.design.topDesignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(diagnostic(
                code: "top_design_missing",
                message: "A non-empty top design is required.",
                actions: ["provide_the_mapped_top_design"]
            ))
        }
        do {
            _ = try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: request.design.designDigest
            )
        } catch {
            diagnostics.append(diagnostic(
                code: "design_digest_invalid",
                message: "Mapped design digest is not a valid SHA-256 digest.",
                actions: ["recreate_the_mapped_design_reference"]
            ))
        }
        let modeIDs = request.requestedModeIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if modeIDs.isEmpty || modeIDs.contains(where: \.isEmpty) || Set(modeIDs).count != modeIDs.count {
            diagnostics.append(diagnostic(
                code: "timing_modes_invalid",
                message: "Production implementation requires unique non-empty timing mode IDs.",
                actions: ["repair_requested_timing_modes"]
            ))
        }
        if request.constraints.kind != .constraint || request.constraints.format != .sdc {
            diagnostics.append(diagnostic(
                code: "physical_constraints_invalid",
                message: "Production implementation requires a canonical SDC constraint artifact.",
                actions: ["provide_sdc_constraints"]
            ))
        }
        do {
            try request.pdk.validate()
        } catch {
            diagnostics.append(diagnostic(
                code: "pdk_reference_invalid",
                message: error.localizedDescription,
                actions: ["recreate_the_pdk_reference"]
            ))
        }
        if request.inputLayout != nil && request.initialSnapshot != nil {
            diagnostics.append(diagnostic(
                code: "ambiguous_input_state",
                message: "Provide either an input layout or an initial snapshot, not both.",
                actions: ["select_one_canonical_input"]
            ))
        }
        if let inputLayout = request.inputLayout,
           inputLayout.layoutArtifact.format != .json && inputLayout.layoutArtifact.format != .def {
            diagnostics.append(diagnostic(
                code: "openroad_input_layout_format_unsupported",
                message: "OpenROAD input layout must be canonical JSON or DEF.",
                actions: ["provide_canonical_json_or_def"]
            ))
        }
        if configuration.executable.toolID.lowercased() != "openroad" {
            diagnostics.append(diagnostic(
                code: "openroad_tool_identity_invalid",
                message: "The configured executable tool ID must identify OpenROAD.",
                actions: ["repair_the_executable_reference"]
            ))
        }
        let requiredInputs = Set(
            [request.design.artifact, request.constraints, request.pdk.manifest]
                + configuration.inputArtifacts
                + (request.inputLayout.map { [$0.layoutArtifact] } ?? [])
        )
        if !requiredInputs.isSubset(of: Set(request.inputs)) {
            diagnostics.append(diagnostic(
                code: "openroad_inputs_incomplete",
                message: "Every OpenROAD, design, constraint, PDK, and input-layout artifact must be retained in request inputs.",
                actions: ["retain_all_production_inputs"]
            ))
        }
        for issue in request.configuration.validationDiagnostics() {
            diagnostics.append(diagnostic(
                code: "physical_design_configuration_invalid",
                message: issue,
                actions: ["repair_physical_design_configuration"]
            ))
        }
        return diagnostics
    }

    private func diagnosticCode(for error: OpenROADExecutionError) -> String {
        switch error {
        case .productionConfigurationMissing: "openroad_configuration_missing"
        case .unsupportedBackend: "physical_design_backend_unsupported"
        case .executableUnavailable: "openroad_executable_unavailable"
        case .executableNotRegularFile: "openroad_executable_not_regular_file"
        case .executableIntegrityMismatch: "openroad_executable_integrity_mismatch"
        case .toolVersionProbeFailed: "openroad_version_probe_failed"
        case .toolVersionMismatch: "openroad_version_mismatch"
        case .inputArtifactInvalid: "openroad_input_artifact_invalid"
        case .processFailed: "openroad_nonzero_exit"
        case .outputDEFUnavailable: "openroad_output_def_missing"
        case .outputDEFInvalid: "openroad_output_def_unsupported"
        case .stageCompletionEvidenceInvalid: "openroad_stage_completion_evidence_invalid"
        case .outputTopCellMismatch: "openroad_output_top_cell_mismatch"
        case .scratchWorkspaceFailed: "openroad_scratch_workspace_failed"
        }
    }

    private func suggestedActions(for error: OpenROADExecutionError) -> [String] {
        switch error {
        case .executableUnavailable, .executableNotRegularFile:
            return ["install_openroad", "provide_an_executable_openroad_path"]
        case .executableIntegrityMismatch, .toolVersionMismatch, .toolVersionProbeFailed:
            return ["recreate_the_openroad_executable_reference", "qualify_the_selected_tool_build"]
        case .inputArtifactInvalid:
            return ["repair_artifact_integrity", "retain_all_production_inputs"]
        case .outputDEFInvalid:
            return ["extend_canonical_def_support", "inspect_openroad_output_def"]
        case .stageCompletionEvidenceInvalid:
            return ["repair_stage_script_completion_contract", "retain_stage_specific_metrics"]
        default:
            return ["inspect_openroad_diagnostics", "repair_the_production_configuration"]
        }
    }

    private var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private struct ScratchWorkspace: Sendable {
        let root: URL
        let inputs: URL
        let home: URL
        let temporary: URL
        let generatedScript: URL
        let outputDEF: URL
        let stageCompletion: URL
    }

    private struct ProcessEnvironment: Sendable {
        let variables: [String: String]
        let fingerprint: ExecutionEnvironmentFingerprint
    }

    private struct ProcessStreamArtifacts: Sendable {
        let script: ArtifactReference
        let stdout: ArtifactReference
        let stderr: ArtifactReference

        var references: [ArtifactReference] { [script, stdout, stderr] }
    }
}
