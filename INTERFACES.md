# PhysicalDesignEngine Interface Contract

## Engine Boundary

`PhysicalDesignStageExecuting` refines CircuiteFoundation `Engine` with
`PhysicalDesignRequest` and `PhysicalDesignResult`. Floorplan, placement, CTS,
routing, ECO and DFM protocols refine the same engine contract. Their native
implementations and `PhysicalDesignEngine` use `NativePhysicalDesignExecutor`.
Canonical ownership, invariants and failure behavior are defined in [DESIGN.md](DESIGN.md).

## Request Schema 5

| Field | Meaning |
|---|---|
| `inputs` / `inputBindings` | Content identities and separate artifact availability |
| `design` | Mapped logical design identity and top cell |
| `constraints` / `requestedModeIDs` | Retained SDC and explicit timing modes |
| `pdk` | Exact process manifest identity |
| `initialSnapshot` / `inputLayout` | Initial physical state or retained JSON/DEF |
| `configuration` | Deterministic geometry and repair controls |
| `executionIntent` | Geometry smoke, characterized CTS, or explicitly unsupported native production |
| `clockTimingModel` | Retained PDK/RC/Liberty/corner characterization |
| `productionConfiguration` | Retained configuration data; not a callable external backend selector |

The decoder accepts only the current schema; changing the schema integer alone
cannot migrate legacy artifacts. `PhysicalDesignArtifactBinding` separates a
logical ID, content reference and availability. Inputs contain the referenced
content identities rather than obsolete path-bearing artifact references.

## Results and Persistence

`PhysicalDesignResult` exposes status, diagnostics, execution provenance,
artifact bindings and a domain payload. A completed native stage writes
`revision.json`, `revision.def`, `design-diff.json` and `run-manifest.json`.
`PhysicalDesignRunManifest` is schema 5. JSON contains the complete execution
state; DEF carries the supported interchange subset described by the design.

Geometry, timing and production claims are distinct observations. Their authority
boundary is defined in [DESIGN.md](DESIGN.md#contracts-and-invariants).
`PhysicalDesignClockTimingModelReference` identifies its model and source bytes;
`LocalPhysicalDesignClockTimingModelLoader` verifies those bytes before decoding.

## External Compatibility

There is no `OpenROADPhysicalDesignExecutor` in this package. Its old implementation
was removed in commit `a3befb7`. Host-only OpenROAD execution now belongs to
[EDAInteroperability](../EDAInteroperability/DESIGN.md), which produces compatibility
and oracle observations. It does not satisfy the native production implementation gate.

## Developer Entry Points

The [retained fixtures](Fixtures/README.md) execute through `physical-design`.
[CLI process tests](Tests/PhysicalDesignEngineTests/PhysicalDesignCLIProcessTests.swift)
verify exact input bytes, successful immutable output bytes, missing-state rejection,
and unsupported-native-production rejection through the actual executable.
