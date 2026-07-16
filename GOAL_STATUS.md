# PhysicalDesignEngine Goal Status

## Current state

**The deterministic native geometry backend and its trust boundaries are implemented. Production place-and-route remains intentionally unavailable.**

| Maturity gate | Status | Evidence |
|---|---|---|
| Direct Foundation contract | Complete | Direct `Engine`, artifact, diagnostic, provenance, and evidence conformance |
| Immutable artifact safety | Complete | Digest/byte verification, immutable paths, canonical root, symlink rejection |
| Canonical JSON / DEF | Complete for supported subset | Parser/writer and retained fixture tests |
| Native geometry stages | Smoke scope complete | Stage regression and physical invariant tests |
| CTS dimensional correctness | Complete | DBU path lengths and characterization-only PS estimates |
| Characterization integrity | Complete | Exact PDK/RC/Liberty/corner artifact loader and monotonic model validation |
| Native production blocking | Complete | `productionEligible` requests fail closed |
| ToolQualification consumption | Contract complete | Canonical process evidence and independent physical correlation validator |
| Physical process corpus | Not supplied | No real PDK/tool corpus artifacts in this repository |
| Production backend | Not implemented | Native backend is heuristic geometry only |
| GDSII/OASIS implementation | Not implemented | Serialization protocol only |
| Release readiness | Blocked | Requires real backend, retained corpus, independent oracle, signoff, and host policy |

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
| GDSII / OASIS | Protocol only | Not applicable | Blocked until implementation and TQ evidence |

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

- Xcode package build passes under a 30-second timeout.
- 40 tests pass after removal of the obsolete self-qualification mask gate.
- Positive and negative CLI fixtures use request schema version 2 and explicit execution intent.

This file must remain evidence-based. A type name or successful smoke fixture is not production qualification.
