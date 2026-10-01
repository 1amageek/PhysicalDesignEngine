# PhysicalDesignEngine Implementation Plan

## Confirmed Baseline

The native engine executes deterministic geometry and characterized CTS through
API and CLI. Production intent remains explicitly unsupported. The owning
contracts are [DESIGN.md](DESIGN.md); current evidence is [GOAL_STATUS.md](GOAL_STATUS.md).
External OpenROAD execution belongs to EDAInteroperability and cannot close a native
implementation gap. The [system production plan](../PRODUCTION_READY_IMPLEMENTATION_PLAN.md)
owns cross-package dependencies and the platform acceptance gate.

## Completed Corrections

Native routing now checks spacing on the actual segment layer and preserves
replacement vias. DEF decoding stops each supported route clause at its boundary.
Behavioral regressions cover rejection, different-layer crossing, repeated routing
and the actual retained multilayer DEF. Developer fixtures use schema 5 and bind
real checked-in input bytes rather than fabricated digests.

Non-square floorplans generate tracks on the correct axis. Signal/ECO routing and
CTS consume configured explicit track directions without parity substitution;
missing directional coverage blocks without artifacts. CTS re-execution replaces
owned branch routes, vias and layer constraints while preserving unrelated nets.
Re-characterization of retained trees remains unsupported and fails explicitly
rather than verifying an estimate produced by a preceding model.

Native scalar technology preparation now consumes exact manifest-bound technology
LEF through existing input bindings. Its supported subset and rejection policy are
owned by [TechnologyConstraints](Sources/PhysicalDesignCore/TechnologyConstraints/DESIGN.md).
This closes the source-to-track preparation portion of N1; full N1 remains open.
Shared native grid admission now checks segment layer/direction, phase and track
count with overflow-safe coordinate subtraction. Unsupported off-grid access fails
instead of snapping pins. Full pin-access search and legal via construction remain open.
Saved manifests retain exact technology availability for subsequent requests;
the [CLI check](Fixtures/README.md) replays these bindings through cumulative routing
and verifies source/grid failures without artifacts.

## Remaining Native Work

These are required implementation outcomes, not claims that an algorithm is
implemented or an API design is settled. Define the affected lower-level contracts,
measured resource bounds and behavioral fixtures before implementing each item.

| ID | Responsibility | Prerequisite | Falsifiable completion evidence |
|---|---|---|---|
| N1 | Consume process-specific legal layers, tracks, cell/pin shapes and via/contact rules | Exact PDK/library views and bounded import/loss policy | Missing or inconsistent views fail; output geometry and connectivity agree with retained source bytes, including non-square cores |
| N2 | Timing-driven legal placement | N1 and real timing graph/corner inputs | Placed cells satisfy legal sites, orientation, overlap and blockage constraints; retained timing and congestion observations drive placement rather than DBU-only proxy scores |
| N3 | Constraint-driven CTS | N2 and characterized buffer/wire models | Every sink is connected; skew, latency, slew and load limits are measured for the exact corner, with rejected candidates and bounded failure/cancellation |
| N4 | Native global/detailed routing beyond single-bend Manhattan geometry | N1/N3 | Obstacle cases can be routed or fail explicitly; legal tracks, widths, layer directions and via stacks satisfy geometry and electrical-connectivity checks; supported standard output preserves those semantics |
| N5 | Close ECO using extraction and timing feedback | Native PEX and STA contracts owned by their packages | Each candidate is followed by exact extraction/timing/DRC/LVS evidence; stale pre-mutation evidence is rejected; a rejected ECO leaves the prior revision intact |
| N6 | Independently qualify the native process scope | N1-N5 plus actual PDK-backed corpus | Distinct oracle identities and retained raw outputs correlate over success, violations, repair, hierarchy, corners and resource bounds; ToolQualification recomputes the decision |

Only N6 plus the host signoff/review/release gates can support production
eligibility. Until then, retain the native unsupported marker and typed failure.

## Verification

Use the non-Metal package's `swift test` with a process timeout and explicitly
built CLI product as documented in [Fixtures/README.md](Fixtures/README.md).
Tests of native geometry cannot establish foundry correctness, full timing closure,
lossless DEF via interchange, or production eligibility.
