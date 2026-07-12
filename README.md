# PhysicalDesignEngine

Floorplan, placement, CTS, routing, ECO, antenna repair and DFM mutation contracts.

## Status

The package provides a deterministic native backend over the canonical `PhysicalDesignSnapshot` JSON IR. It emits immutable JSON and DEF revisions, machine-readable design diffs, structured diagnostics, and a headless Xcircuite stage adapter. Native execution is smoke-tested against the retained fixtures; process-specific qualification and GDSII/OASIS stream-out remain explicit external boundaries.

## Products

| Product | Responsibility |
|---|---|
| `PhysicalDesignCore` | Canonical snapshot, request, immutable layout reference and run manifest |
| `FloorplanEngine` | Floorplan and power planning |
| `PlacementEngine` | Global and detailed placement |
| `CTSEngine` | Clock-tree synthesis |
| `RoutingEngine` | Global and detailed routing |
| `PhysicalECO` | Timing, DRC and antenna repair |
| `PhysicalDFM` | Fill, redundant via and manufacturability mutation |
| `PhysicalDesignEngine` | Umbrella API |
| `PhysicalDesignCLISupport` / `physical-design` | Deterministic JSON CLI |

## Contract

Every executing product uses:

- a `Codable`, `Hashable`, `Sendable` request conforming to `XcircuiteEngineRequest`;
- `XcircuiteEngineResultEnvelope<Payload>` for status, diagnostics, artifacts and execution metadata;
- protocol-first dependency injection;
- immutable `XcircuiteFileReference` inputs and outputs;
- explicit blocked, failed and cancelled states.

Native execution additionally uses:

- `PhysicalDesignSnapshot` as the canonical, UI-independent physical state;
- `PhysicalDesignArtifactStore` for dependency-injected immutable artifact I/O;
- `PhysicalDesignDiffBuilder` for reviewable `XcircuiteDesignDiff` artifacts;
- `PhysicalDesignConfiguration` for typed, deterministic stage controls.

The native backend supports canonical JSON input and emits canonical JSON plus DEF. Unsupported opaque layout formats return `blocked`; no native result claims DRC, LVS, PEX, timing, GDSII, OASIS, or foundry qualification.

## Xcircuite integration

Xcircuite owns the closure loop. Physical products emit immutable layout revisions; Xcircuite sends them to DRC, LVS, PEX and Timing, then constructs typed repair requests.

The library does not depend on the Xcircuite runtime. Xcircuite owns the adapter to `DesignFlowKernel.FlowStageExecutor`, artifact persistence, qualification gates, repair loops and human approval.

## Build

```bash
swift build
```

## CLI

```bash
swift run physical-design --request Fixtures/positive-floorplan-request.json --project-root .
swift run physical-design --request Fixtures/negative-missing-snapshot-request.json --project-root .
```

The command emits one JSON result envelope. Successful runs write `revision.json`, `revision.def`, `design-diff.json`, and `run-manifest.json` under `runs/<run-id>/physical-design/<stage>/`.

## Test

```bash
swift test
```

The current native regression suite covers JSON compatibility, all declared native stages, blocked prerequisites, stage boundaries, artifact provenance and CLI error output. The positive fixture completes with four immutable artifacts; the negative fixture is blocked with `physical_snapshot_missing`.

The Xcircuite adapter is verified from the sibling repository with:

```bash
swift test --scratch-path /tmp/lsi-xcircuite-physical-design --filter PhysicalDesignFlowStageExecutorTests
```

See [MILESTONES.md](MILESTONES.md) for the release/readiness path. M1, the immutable run transaction, is complete for the native canonical-snapshot scope; M2, standard layout interchange, is next.

See `DESIGN.md`, `INTERFACES.md`, `IMPLEMENTATION_PLAN.md`, and `CAPABILITY.md` for the boundary and qualification status.
