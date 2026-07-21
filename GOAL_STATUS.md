# PhysicalDesignEngine Goal Status

## Current state

**The deterministic native backend and a directly conforming OpenROAD process backend are implemented. Installed OpenROAD/PDK qualification and real-process eligibility remain external evidence requirements.**

| Maturity gate | Status | Evidence |
|---|---|---|
| Direct Foundation contract | Complete | Direct `Engine`, artifact, diagnostic, provenance, and evidence conformance |
| Immutable artifact safety | Complete | Digest/byte verification, immutable paths, canonical root, symlink rejection |
| Canonical JSON / DEF | Complete for supported subset | Parser/writer and retained fixture tests |
| Native geometry stages | Smoke scope complete | Stage regression and physical invariant tests |
| CTS dimensional correctness | Complete | DBU path lengths and characterization-only PS estimates |
| Characterization integrity | Complete | Exact PDK/RC/Liberty/corner artifact loader and monotonic model validation |
| Native production blocking | Complete | `productionImplementation` requests dispatch only to OpenROAD and never fall back to native geometry |
| ToolQualification consumption | Contract complete | Canonical process evidence and independent physical correlation validator |
| Physical process corpus | Not supplied | No real PDK/tool corpus artifacts in this repository |
| Production process backend | Callable contract complete | Exact executable/views, isolated process, timeout/tree cleanup, DEF/log/evidence retention |
| Installed OpenROAD + PDK corpus | Not supplied | No local OpenROAD executable or real process corpus is bundled |
| GDSII/OASIS implementation | External responsibility | Dedicated standard mask-data library and host composition required |
| Release readiness | Blocked | Requires installed tool, retained real corpus, independent oracle, signoff, and host policy |

## Function status

| Function | Native implementation | Timing meaning | Production status |
|---|---|---|---|
| Floorplan / power planning | Deterministic geometry | No timing claim | Blocked |
| Placement | Row legalizer and wirelength/congestion proof | DBU proxy only | Blocked |
| CTS | Buffers, branch nets, routes, vias, route constraints | PS only with exact characterization | Blocked |
| Global/detailed routing | Manhattan geometry and native conflict checks | No signoff timing claim | Blocked |
| Physical ECO | Typed reviewable mutations | Requires independent Timing/DRC feedback | Blocked |
| Antenna / DFM | Repair candidates and native proof | No signoff claim | Blocked |
| JSON / DEF artifacts | Immutable and verified | Not applicable | Complete for interchange subset |
| GDSII / OASIS | Not exposed | Not applicable | Dedicated exporter and TQ evidence required |
| OpenROAD process execution | Exact executable and view binding | Tool output retained as standard DEF | Callable; qualification external |

## Trust progression

```mermaid
flowchart LR
  G["Native geometry smoke"] --> C["Characterized CTS timing"]
  C --> Q["ToolQualification process evidence"]
  Q --> O["Independent raw oracle result"]
  O --> F["DesignFlowKernel policy / approval"]
  F --> R["Release eligibility"]
```

No arrow is implicit. In particular, characterized timing does not imply process qualification, and process qualification does not itself approve a design run or release.

## Verified regression state

- Xcode package build passes under a timeout-bounded compile gate.
- The four OpenROAD focused tests pass, covering unavailable tools, successful execution evidence, non-zero exit evidence, and timeout evidence.
- The prior 42-test native regression baseline remains subject to the workspace-level consolidated matrix after this schema change.
- Positive and negative CLI fixtures use request schema version 4 and explicit execution intent.
- The OpenROAD focused suite verifies unavailable-tool blocking, successful process evidence retention, and non-zero exit evidence without claiming tool qualification.

This file must remain evidence-based. A type name or successful smoke fixture is not production qualification.
