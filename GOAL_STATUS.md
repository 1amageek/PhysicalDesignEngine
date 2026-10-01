# PhysicalDesignEngine Goal Status

Updated: 2026-10-01

The native geometry subset is executable. Native production physical design is
not implemented, and OpenROAD is not a backend of this package. External
compatibility execution belongs to EDAInteroperability. Installing or qualifying
OpenROAD alone cannot complete PhysicalDesignEngine.

| Capability | Current claim | Evidence / remaining gap |
|---|---|---|
| Native stage API | Executable subset | `PhysicalDesignEngine` and stage wrappers delegate to the shared native executor |
| Floorplan / power / placement | Deterministic geometry | Non-square track extent and JSON/DEF persistence tests; process-specific and timing-driven closure remain |
| CTS | Geometry; model-bound PS estimate for newly constructed trees | Explicit track selection and branch re-execution tests; retained-tree re-characterization is blocked; full corner/load/slew closure remains |
| Routing / ECO | Limited native Manhattan geometry | Actual-layer spacing, configured track directions and rerouting-via regressions; track-grid access, obstacle search, process-legal via stacks and timing feedback remain |
| Canonical artifacts | Immutable JSON, supported DEF, diff and manifest | Byte verification, tamper and review tests; DEF is not full execution-state serialization |
| Developer CLI | Current schema-5 retained inputs | Actual CLI positive/missing-state/unsupported-production fixtures and digest verification |
| Native production intent | Explicitly unsupported | `ProductionEvidenceTests.productionImplementationFailsClosed`; incomplete implementation marker retained |
| Tool trust / release | Owned outside this package | Independent native-process correlation, complete signoff and exact human approval remain required |

## Current Verification

Verification uses Swift 6.4.0 on macOS arm64. All 54 package tests in four suites
pass, including three retained CLI request cases, with a 120-second process timeout. The routing corrections fail against
the old code and pass against the current code. Existing native API, artifact,
review, stage and characterized-CTS regressions pass. The CLI process test requires
an explicitly built executable and `BUILT_PRODUCTS_DIR` when the SwiftPM test runner
cannot infer its product directory. Reproducible commands and the synthetic fixture
scope are documented in [Fixtures/README.md](Fixtures/README.md).

The directional-track matrix covers 20 cases across global routing, detailed
routing, ECO and CTS, including missing directions and excluded layers. CTS
re-execution changes layer pairs without retaining stale vias or duplicating
branches; a changed timing model cannot verify the preceding estimate.

No WASM, Embedded, foundry PDK, production timing closure or platform release claim
is inferred from this macOS package verification. Remaining native implementation
outcomes and acceptance evidence are tracked in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).
