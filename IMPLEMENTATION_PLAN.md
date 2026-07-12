# PhysicalDesignEngine Implementation Plan

## Order

1. Immutable physical transaction, provenance manifest and resume identity
2. Standard DEF interchange and parser diagnostics
3. Floorplan, IO and power-domain model
4. Placement with timing/congestion objectives
5. CTS materialization and clock constraints
6. Global/detailed routing with rule-aware diagnostics
7. ECO and antenna repair closure
8. DFM mutation and density evidence
9. Retained corpus, oracle correlation and process qualification

## First implementation slice

- Implement the canonical-snapshot native backend for all declared physical stages.
- Add deterministic positive and negative fixtures.
- Add JSON request/result round-trip and stage regression tests.
- Add a deterministic JSON CLI surface.
- Add a headless Xcircuite adapter test with artifact integrity verification.
- Keep process qualification and reference-oracle correlation as explicit evidence gates.

## Completion gates

- Public APIs remain protocol-first and Sendable.
- Every unsupported semantic produces a structured blocked result.
- Native and external backends produce the same result schema.
- No UI type enters a public contract.
- No result claims foundry qualification without process-scoped oracle evidence.
- Xcircuite can execute, persist, review and resume the stage without circuit-studio.

## Delivered implementation slice

The native backend now covers floorplan, power planning, placement, CTS, global and detailed routing, timing/DRC ECO actions, antenna repair, fill insertion, redundant-via insertion and hotspot repair. Every completed mutation creates a new snapshot digest and design diff. Missing canonical state, unsupported layout formats, invalid geometry, missing clock/connectivity, and unavailable repair targets return structured `blocked` results.

Remaining release gates are process-specific corpus retention, reference-oracle correlation, qualification evidence, and a qualified GDSII/OASIS stream-out adapter.

The next implementation slice is M5 in `MILESTONES.md`: bind human approval, rejection, stale-base detection and resume identity to immutable run manifests and Xcircuite flow results.
