# PhysicalDesignEngine Goal Status

## Current state

**Canonical native backend implemented. Process qualification and foundry-facing external adapters remain intentionally unclaimed.**

Milestone status: M0 complete, M0.5 CircuiteFoundation boundary complete, M1 immutable run transaction complete, M2 supported DEF interchange complete, M3 native rule-aware implementation complete, M4 native repair/DFM closure complete, M5 native approval/resume boundary complete, M6 corpus and oracle correlation next.

| Maturity gate | Status | Evidence |
|---|---|---|
| Responsibility boundary | Complete | README.md and DESIGN.md |
| CircuiteFoundation dependency and evidence boundary | Complete for the migration slice | `PhysicalDesignFoundationExecuting`, `PhysicalDesignFoundationResult`, `PhysicalDesignFoundationEvidence`, conversion and integration tests |
| Public package products | Implemented for native scope | Package.swift and native products |
| Shared Xcircuite request/result contract | Implemented for native scope | Public Swift protocols and payloads |
| Contract build | Passed | swift build |
| Contract test | Passed | timeout-bounded `swift test` (37 tests) |
| Domain implementation | Smoke-checked | `NativePhysicalDesignExecutor` and stage regression tests |
| CLI implementation | Complete | `physical-design` executable and JSON fixtures |
| Fixture corpus | Smoke-checked | `Fixtures/` positive and negative requests |
| Oracle correlation | Not started | No retained comparison evidence |
| Process qualification | Not started | No PDK-scoped qualification record |
| Xcircuite stage adapter | Smoke-checked | `PhysicalDesignFlowStageExecutor` and headless tests |
| End-to-end flow evidence | Smoke-checked | Native floorplan adapter persists and verifies immutable artifacts; review gate verifies immutable manifest identity before resume |
| Release readiness | Blocked | Process qualification, retained corpus and oracle correlation are absent |

## Function status

| Function | Contract | Implementation | Validation corpus | Qualification |
|---|---|---|---|---|
| Floorplan and IO planning | Contract defined | Native canonical backend | Fixture smoke test | Not process-qualified |
| Power planning | Contract defined | Native canonical backend | Stage regression | Not process-qualified |
| Placement | Contract defined | Blockage-aware legalizer with placement proof and objective metrics | Placement proof regression | Not process-qualified |
| Clock-tree synthesis | Contract defined | Materialized clock buffers, branch nets and route constraints | CTS materialization regression | Not process-qualified |
| Routing | Contract defined | Directional layers, bend vias, blockage/spacing checks and antenna evidence | Routing evidence/blockage regression | Not process-qualified |
| Physical ECO | Contract defined | Typed native actions | Stage regression | Not process-qualified |
| Antenna repair | Contract defined | Native repair candidates | Stage regression | External DRC required |
| Physical DFM | Contract defined | Native fill/via/hotspot candidates | Stage regression | External DRC required |
| Immutable revisions | Contract defined | JSON/DEF/diff/run-manifest artifacts | Integrity gate test | Complete for native scope |
| Repair/DFM closure | Contract defined | Rule-aware ECO, antenna, fill, via and hotspot candidates with repair proofs | Strategy and DFM proof regression | Complete for native scope |
| DEF interchange | Contract defined | Native parser/writer with structured diagnostics and source provenance | Round-trip, retained fixture and DEF input tests | Complete for supported subset |
| GDSII/OASIS adapter boundary | Protocol defined | Qualification-gated external adapter protocol | Gate contract pending external implementation | Blocked until qualified |
| Approval and resume identity | Contract defined | Immutable review packet, decision and current-byte revalidation gate | 37-test native regression suite | Native boundary complete; ledger persistence owned by Xcircuite |
| CircuiteFoundation projection | Contract defined | Foundation engine/evidence adapter, verified artifact conversion and stable design identity | Foundation integration regression | Complete for the migration slice |

## Goal progression

```text
contract recovery
      ↓
CircuiteFoundation engine/evidence boundary
      ↓
immutable run transaction
      ↓
standard layout interchange
      ↓
physical implementation algorithms
      ↓
repair and DFM closure
      ↓
approval and resume
      ↓
corpus validation
      ↓
reference-oracle correlation
      ↓
process-scoped qualification
      ↓
Xcircuite integration and repair loop
      ↓
release-profile eligibility
```

## Completion definition

The package goal is complete only when every P0 function has a concrete backend, structured failure behavior, retained corpus, reference correlation where an oracle exists, process-scoped qualification where required, a deterministic CLI and a passing Xcircuite headless integration test.

## Current blockers

- No process-specific corpus or reference-oracle correlation has been retained.
- No PDK-scoped process qualification record exists.
- GDSII and OASIS stream-out require a qualified external adapter.
- Native repair candidates still require independent DRC/LVS/PEX/Timing verification.
- Xcircuite must persist the native review packet and approval decision in its run ledger and call the native resume gate before continuing a physical stage.

This file must be updated by implementation agents whenever a maturity gate changes. A source file or type name alone is never evidence of implementation or qualification.
