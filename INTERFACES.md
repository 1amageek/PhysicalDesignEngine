# PhysicalDesignEngine Interface Contract

## Common shape

```swift
public protocol DomainExecuting: Sendable {
    func execute(
        _ request: DomainRequest
    ) async throws -> XcircuiteEngineResultEnvelope<DomainPayload>
}
```

Requests carry a schema version, run ID and typed artifact references. Payloads contain domain metrics only. Diagnostics and artifacts belong to the shared envelope.

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
8. leave approval and resume handling to DesignFlowKernel.
