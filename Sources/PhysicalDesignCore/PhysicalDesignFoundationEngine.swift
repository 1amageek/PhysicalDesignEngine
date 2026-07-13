import Foundation
import XcircuitePackage

/// Foundation boundary adapter for the existing Xcircuite-backed executor.
///
/// The adapter does not infer or hash unverified input artifacts. It exposes
/// only the immutable output references and execution timestamps that the
/// legacy executor has actually materialized.
public struct PhysicalDesignFoundationEngine: PhysicalDesignFoundationExecuting {
    public let legacyEngine: any PhysicalDesignStageExecuting

    public init(legacyEngine: any PhysicalDesignStageExecuting) {
        self.legacyEngine = legacyEngine
    }

    public func execute(
        _ request: PhysicalDesignRequest
    ) async throws -> PhysicalDesignFoundationResult {
        let legacyResult = try await legacyEngine.execute(request)
        let artifacts = try PhysicalDesignFoundationArtifactConversion.references(
            from: legacyResult.artifacts
        )
        let diagnostics = try legacyResult.diagnostics.map(Self.makeDiagnostic)
        let provenance = try makeProvenance(metadata: legacyResult.metadata)
        return PhysicalDesignFoundationResult(
            runID: legacyResult.runID,
            stage: request.stage,
            status: Self.status(from: legacyResult.status),
            changedObjectCount: legacyResult.payload.changedObjectCount,
            candidateActions: legacyResult.payload.candidateActions,
            metrics: legacyResult.payload.metrics,
            artifacts: artifacts,
            diagnostics: diagnostics,
            provenance: provenance
        )
    }

    private func makeProvenance(
        metadata: XcircuiteEngineExecutionMetadata
    ) throws -> ExecutionProvenance {
        let producer = try ProducerIdentity(
            kind: .engine,
            identifier: metadata.engineID,
            version: metadata.implementationVersion,
            build: metadata.implementationID
        )
        return try ExecutionProvenance(
            producer: producer,
            designRevision: nil,
            randomSeed: metadata.seed,
            startedAt: metadata.startedAt,
            completedAt: metadata.completedAt
        )
    }

    private static func status(
        from status: XcircuiteEngineExecutionStatus
    ) -> PhysicalDesignFoundationExecutionStatus {
        switch status {
        case .completed: .completed
        case .failed: .failed
        case .blocked: .blocked
        case .cancelled: .cancelled
        }
    }

    private static func makeDiagnostic(
        _ diagnostic: XcircuiteEngineDiagnostic
    ) throws -> DesignDiagnostic {
        let rawCode = diagnostic.code.hasPrefix("physical-design.")
            ? diagnostic.code
            : "physical-design.\(diagnostic.code)"
        let code = try DiagnosticCode(rawValue: rawCode)
        let severity: DiagnosticSeverity
        switch diagnostic.severity {
        case .info: severity = .information
        case .warning: severity = .warning
        case .error: severity = .error
        }
        let detail = diagnostic.entity.map { "entity=\($0)" }
        let actions = diagnostic.suggestedActions.map {
            SuggestedAction(code: "physical-design.action", summary: $0)
        }
        return DesignDiagnostic(
            code: code,
            severity: severity,
            summary: diagnostic.message,
            detail: detail,
            suggestedActions: actions
        )
    }
}
