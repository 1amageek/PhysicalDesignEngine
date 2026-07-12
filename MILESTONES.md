# PhysicalDesignEngine milestone plan

The package goal is a trustworthy physical-design substrate, not a collection of stage-shaped mocks. Milestones are ordered by the dependencies required for reproducibility and qualification.

```mermaid
flowchart LR
  M0[Contract recovery] --> M1[Immutable run transaction]
  M1 --> M2[Standard layout interchange]
  M2 --> M3[Physical implementation algorithms]
  M3 --> M4[Repair and DFM closure]
  M4 --> M5[Xcircuite approval/resume flow]
  M5 --> M6[Retained corpus and oracle correlation]
  M6 --> M7[Process qualification and release profile]
```

## M0 — Contract recovery and honest capability map

Status: complete.

Acceptance criteria:

- Read the package goal, boundaries and required developer surfaces.
- Identify scaffolded, smoke-checked, qualified and blocked capabilities separately.
- Preserve the boundary that DRC, LVS, PEX and Timing remain independent oracles.

Evidence: `GOAL_STATUS.md`, `CAPABILITY.md`, package and Xcircuite contract tests.

## M1 — Immutable physical-design run transaction

Status: complete for the native canonical-snapshot scope.

Acceptance criteria:

- Every completed mutation binds design digest, timing constraints, PDK process/version/digest, base revision, proposed revision, diff, seed and implementation identity.
- The binding is persisted as a JSON artifact and included in the result envelope.
- The manifest validates its cross-reference invariants and is integrity-gated by Xcircuite.
- Older schema-version-one requests and payloads remain decodable.

Evidence: `PhysicalDesignRunManifest`, `run-manifest.json` output, timeout-bounded native regression tests, and Xcircuite adapter integrity tests.

## M2 — Standard layout interchange

Status: complete for the supported native DEF subset; GDSII/OASIS remain qualified external boundaries.

Acceptance criteria:

- Parse and validate the supported DEF subset into the canonical snapshot with line/section diagnostics.
- Export deterministic DEF with rows, components, pins, nets, blockages and power structures.
- Define protocol-first GDSII/OASIS adapters; the adapter gate returns an explicit qualification error until a qualified implementation is available.
- Preserve source format, digest and parser version in the run manifest.

Evidence: `PhysicalDesignDEFParser`, `PhysicalDesignDEFWriter`, `PhysicalDesignMaskDataAdapter`, `Fixtures/positive-interchange.def`, DEF round-trip/diagnostic/provenance tests, and the native capability declaration.

## M3 — Physical implementation algorithms

Status: complete for the deterministic native rule-aware slice; process qualification and oracle correlation remain open.

Acceptance criteria:

- Floorplan supports hierarchy, IO pins/pads, blockages, rows, tracks and power domains.
- Placement consumes timing and congestion objectives and reports legal-placement proof data.
- CTS materializes buffers, clock connectivity and route constraints, not only estimated tree records.
- Routing accounts for blockages, layer direction, vias, spacing and antenna risk with structured failure diagnostics.

Evidence: `PhysicalDesignImplementationState`, `PhysicalDesignImplementationConstraints`, native floorplan/placement/CTS/routing paths, implementation proof and routing regression tests, and immutable diff/run-manifest persistence.

## M4 — Repair and DFM closure

Status: complete for the native rule-aware repair slice; external oracle recheck and process qualification remain open.

Acceptance criteria:

- ECO actions are typed, scoped, diffed and independently rechecked by the relevant oracle.
- Antenna repair supports reroute, jumper and protection-device strategies without claiming a DRC verdict.
- Fill, redundant-via and hotspot operations are window/rule aware and produce reviewable candidates.

Evidence: `PhysicalDesignRepairConstraints`, `PhysicalDesignAntennaRepairStrategy`, `PhysicalDesignImplementationState.RepairProof`, repair strategy regression tests, and fail-closed native verification diagnostics.

## M5 — Xcircuite approval and resume flow

Status: next; partially smoke-checked.

Acceptance criteria:

- A run can pause at a human approval boundary with immutable artifacts and a decision packet.
- Resume verifies the same base revision, manifest and approval scope before continuing.
- Rejected or stale revisions fail closed and leave the prior immutable revision untouched.

## M6 — Retained corpus and reference-oracle correlation

Status: planned.

Acceptance criteria:

- Retain positive, negative, boundary and regression cases per PDK profile.
- Compare native/external results against a declared reference oracle with tolerances and evidence artifacts.
- Track unsupported semantics and corpus coverage explicitly.

## M7 — Process qualification and release profile

Status: planned.

Acceptance criteria:

- Tool binary/implementation/deck/process qualification is recorded separately from execution capability.
- Required gates are evaluated by ToolQualification and ReleaseEngine.
- Release readiness is denied until all required evidence is complete, consistent and reviewable.
