# PhysicalDesignEngine Interface Contract

## Common shape

```swift
public protocol DomainExecuting: Sendable {
    func execute(
        _ request: DomainRequest
    ) async throws -> XcircuiteEngineResultEnvelope<DomainPayload>
}
```

Requests carry a schema version, run ID and typed artifact references. Payloads contain domain metrics only. Diagnostics and artifacts belong to the shared envelope during the compatibility migration. Cross-engine consumers use the Foundation seam below.

## CircuiteFoundation seam

```swift
public protocol PhysicalDesignFoundationExecuting: Engine
where Request == PhysicalDesignRequest,
      Output == PhysicalDesignFoundationResult {}
```

`PhysicalDesignFoundationEngine` adapts the native Xcircuite-backed executor
without introducing an `AgentHarness` or another orchestration wrapper. The
adapter projects completed output references into Foundation
`ArtifactReference` values only when digest and byte-count metadata are
present, maps diagnostics to `DesignDiagnostic`, and records producer/time/
seed data in `ExecutionProvenance` and `EvidenceManifest`.

`PhysicalDesignFoundationEvidence` provides the same evidence and diagnostic
surface independently of the execution result. `PhysicalDesignRequest` also
exposes a stable root-cell `DesignObjectReference`.

## Products

### PhysicalDesignCore

Shared physical-design request, canonical snapshot, immutable layout reference, artifact store, metrics and design-diff contract.

### FloorplanEngine

Floorplan and power planning.

### PlacementEngine

Global and detailed placement.

### CTSEngine

Clock-tree synthesis.

### RoutingEngine

Global and detailed routing.

### PhysicalECO

Timing, DRC and antenna repair.

### PhysicalDFM

Fill, redundant via and manufacturability mutation.

### PhysicalDesignEngine

Umbrella API. `PhysicalDesignEngine` dispatches the request stage to the deterministic native implementation while preserving the common result envelope.

### Canonical input and output

`PhysicalDesignRequest` accepts either `initialSnapshot` or `inputLayout`, never both. Native execution reads canonical JSON or the supported DEF subset. A completed mutation emits:

| Artifact | Format | Purpose |
|---|---|---|
| `revision.json` | JSON | Canonical immutable physical snapshot |
| `revision.def` | DEF | Standard layout handoff for supported native output |
| `design-diff.json` | JSON | `XcircuiteDesignDiff` for human review and Agent resume |
| `run-manifest.json` | JSON | Provenance binding for the complete physical-design transaction |

Each output reference records format, digest, byte count and producer run ID.

`PhysicalDesignMaskDataAdapter` is the protocol boundary for future GDSII/OASIS adapters. `PhysicalDesignMaskDataAdapterGate` requires a matching format and explicit process qualification before invoking an adapter.

`PhysicalDesignSnapshot.implementationState` is the canonical evidence surface for M3. It carries generated tracks, power domains, pads, placement proof, clock route constraints and routing evidence. These fields are included in JSON revisions and `XcircuiteDesignDiff`; the run manifest also records the implementation configuration used to produce them.

M4 repair requests use `PhysicalDesignConfiguration.repairConstraints`. A completed repair appends `PhysicalDesignImplementationState.RepairProof`; when verification is required and native post-repair checks find a violation, the executor returns `blocked` and writes no immutable revision.

### Review and resume boundary

`PhysicalDesignReviewGating` is the protocol-first approval boundary for immutable native results:

```mermaid
flowchart LR
  Manifest["Completed run manifest"] --> Packet["Review packet"]
  Packet --> Decision["Approval or rejection decision"]
  Decision -->|approved| Resume["Resume validation"]
  Decision -->|rejected| Blocked["Rejected / blocked"]
  Resume -->|same identities and digests| Ready["Ready to resume"]
  Resume -->|stale or mismatched| Blocked
```

`PhysicalDesignReviewGate.prepareReview` reads the manifest and all manifest artifacts through the injected `PhysicalDesignArtifactStore`. It verifies artifact bytes, SHA-256 digests, byte counts, the proposed layout digest and the design-diff binding before returning `PhysicalDesignReviewPacket`. `evaluate` returns `approved`, `rejected` or `blocked`. `validateResume` returns `readyToResume` only when the approval is bound to the same run ID, stage, manifest digest, proposed layout digest, optional base layout digest and complete decision scope. The packet and decision are Codable artifacts; Xcircuite persists them and records the ledger action.


## Error contract

- Throw only when execution cannot produce a valid result envelope.
- Represent design findings and failed checks as typed diagnostics and a completed domain payload.
- Represent missing prerequisites or insufficient semantics as `blocked`.
- Preserve cancellation as `cancelled`.
- Do not swallow parser, process or persistence failures.

## Xcircuite adapter

The adapter must:

1. resolve project-relative references through XcircuitePackage;
2. verify input digests;
3. evaluate ToolQualification requirements;
4. invoke the injected engine protocol;
5. persist every returned artifact;
6. map diagnostics and status to FlowStageResult;
7. attach design, PDK and tool provenance;
8. persist the review packet and approval in the run ledger;
9. revalidate current packet artifact bytes and the embedded manifest in the synchronous Xcircuite approval hook, then invoke `PhysicalDesignReviewGate.validateResume`; direct asynchronous integrations use `validateResumeAgainstCurrentArtifacts`;
10. leave flow scheduling and stage ordering to DesignFlowKernel.
