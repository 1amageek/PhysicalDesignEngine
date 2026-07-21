# PhysicalDesignEngine Design

## Purpose

PhysicalDesignEngine owns typed physical-design state, stage protocols, deterministic native geometry mutations, and evidence needed to review those mutations. It remains usable without UI state or the Xcircuite runtime.

## Responsibility boundary

```mermaid
flowchart TD
  F["CircuiteFoundation\nartifact / diagnostic / provenance"] --> P["PhysicalDesignEngine\nphysical state and stage execution"]
  T["ToolQualification\nprocess trust evidence"] --> P
  P --> K["DesignFlowKernel\napproval / resume / flow policy"]
  P --> X["Xcircuite\nworkspace persistence and composition"]
```

PhysicalDesignEngine owns:

- canonical `PhysicalDesignSnapshot` geometry and implementation proof state;
- direct `Engine`-conforming stage protocols;
- immutable JSON/DEF/diff/manifest output;
- PDK/RC/Liberty/corner-bound clock timing estimates;
- physical oracle-correlation records consumed with ToolQualification evidence.
- isolated OpenROAD execution bound to exact executable and PDK-view bytes.

It does not own:

- tool qualification or production eligibility issuance;
- flow approval, release policy, or run lifecycle;
- final DRC, LVS, PEX, timing, density, antenna, EM/IR, or tapeout verdicts;
- a concrete GDSII/OASIS implementation.

## Three execution meanings

| Layer | Inputs | Output claim |
|---|---|---|
| Geometry smoke | Canonical snapshot and deterministic configuration | Geometry invariants only |
| Characterized CTS | Geometry plus exact PDK/RC/Liberty/corner model artifacts | Clock timing estimate for that retained model |
| Production process backend | Exact executable, PDK views, netlist, SDC, RC setup, stage script, and corner | Standard DEF and raw process evidence; eligibility remains blocked for independent policy |

`characterizedTiming` and `productionImplementation` are intentionally separate. A valid RC/cell model can support a timing estimate without proving the placement/routing algorithm, rule deck, executable, corpus, or oracle correlation.

## Dimensional model

Geometry fields use database units (`DBU`). Time fields use picoseconds (`PS`) and appear only in `PhysicalDesignClockTimingEstimate`.

```mermaid
flowchart LR
  Geometry["Clock path length (DBU)"] --> Model["PDK + RC + Liberty + corner model"]
  Cells["Retained buffer masters"] --> Model
  Model --> Time["Latency / skew (PS)"]
```

The native CTS algorithm never compares DBU distance with a picosecond target and never derives time by copying a path length. Wire-delay samples must increase in path length without decreasing delay. Interpolation is bounded to the retained characterization range; extrapolation and missing cell delays are typed errors.

## Production trust boundary

PhysicalDesignEngine emits revisions, diffs, implementation identity, and raw
correlation artifacts. ToolQualification reads those immutable artifacts and
owns tool trust. The package neither reconstructs a trust record nor evaluates
approval or release policy.

The `OpenROADPhysicalDesignExecutor` directly conforms to `PhysicalDesignStageExecuting`. It is not an adapter and it does not wrap a native success. It verifies the executable before and after execution, materializes byte-verified inputs into an isolated working directory, applies process timeout and process-group cancellation, and retains generated Tcl, stdout, stderr, DEF, and process evidence.

```mermaid
flowchart LR
  Inputs["Verilog / SDC / LEF / Liberty / RC / PDK"] --> Verify["Digest and byte verification"]
  Verify --> OpenROAD["OpenROAD isolated process"]
  OpenROAD --> Raw["DEF / stdout / stderr / invocation"]
  Raw --> Canonical["Canonical snapshot / diff / manifest"]
  Raw --> TQ["ToolQualification + independent oracle"]
```

## Artifact safety

All artifact locations are workspace-relative. The filesystem store resolves the configured root canonically, checks each parent and leaf against that root, rejects symlink traversal, verifies byte count and SHA-256 on read, and uses immutable destination paths on write.

Artifact review validation in this package prepares an immutable review packet and revalidates its current bytes. DesignFlowKernel owns approval decisions, resume, and lifecycle transitions.

## Foreign format boundary

PhysicalDesignEngine emits canonical JSON and its supported DEF subset. A host
composes those results with a dedicated standard mask-data library for
GDSII/OASIS stream-out. The exporter contract and implementation belong to
that library; ToolQualification and host release policy evaluate the concrete
toolchain.
