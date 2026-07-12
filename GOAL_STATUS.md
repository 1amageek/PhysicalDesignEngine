# PhysicalDesignEngine Goal Status

## Current state

**Canonical native backend implemented. Process qualification and foundry-facing external adapters remain intentionally unclaimed.**

Milestone status: M0 complete, M1 immutable run transaction complete for the native canonical-snapshot scope, M2 standard layout interchange is next.

| Maturity gate | Status | Evidence |
|---|---|---|
| Responsibility boundary | Complete | README.md and DESIGN.md |
| Public package products | Implemented for native scope | Package.swift and native products |
| Shared Xcircuite request/result contract | Implemented for native scope | Public Swift protocols and payloads |
| Contract build | Passed | swift build |
| Contract test | Passed | timeout-bounded xcodebuild test |
| Domain implementation | Smoke-checked | `NativePhysicalDesignExecutor` and stage regression tests |
| CLI implementation | Complete | `physical-design` executable and JSON fixtures |
| Fixture corpus | Smoke-checked | `Fixtures/` positive and negative requests |
| Oracle correlation | Not started | No retained comparison evidence |
| Process qualification | Not started | No PDK-scoped qualification record |
| Xcircuite stage adapter | Smoke-checked | `PhysicalDesignFlowStageExecutor` and headless tests |
| End-to-end flow evidence | Smoke-checked | Native floorplan adapter persists and verifies immutable artifacts |
| Release readiness | Blocked | Implementation and qualification are absent |

## Function status

| Function | Contract | Implementation | Validation corpus | Qualification |
|---|---|---|---|---|
| Floorplan and IO planning | Contract defined | Native canonical backend | Fixture smoke test | Not process-qualified |
| Power planning | Contract defined | Native canonical backend | Stage regression | Not process-qualified |
| Placement | Contract defined | Native legalizer | Stage regression | Not process-qualified |
| Clock-tree synthesis | Contract defined | Native topology estimator | Stage regression | Not process-qualified |
| Routing | Contract defined | Native Manhattan router | Stage regression | Not process-qualified |
| Physical ECO | Contract defined | Typed native actions | Stage regression | Not process-qualified |
| Antenna repair | Contract defined | Native repair candidates | Stage regression | External DRC required |
| Physical DFM | Contract defined | Native fill/via/hotspot candidates | Stage regression | External DRC required |
| Immutable revisions | Contract defined | JSON/DEF/diff/run-manifest artifacts | Integrity gate test | Complete for native scope |

## Goal progression

```text
contract recovery
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

This file must be updated by implementation agents whenever a maturity gate changes. A source file or type name alone is never evidence of implementation or qualification.
