# Legal Placement

## Purpose and Scope

Own bounded deterministic legal-row allocation for native placement.
Parent: [PhysicalDesignCore](../DESIGN.md). No children. Timing-driven placement,
routing, CTS and production qualification remain separate responsibilities.

## Responsibilities and Boundaries

Consume validated rows, actual cell bounds, blockages and exact process geometry.
Search legal source orientations and site locations while preserving locked cells.
ProcessGeometry owns source projection, symmetry and pin reconstruction. The native
executor owns input identity, final admission and immutable artifact publication.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent / used by | Native mutation and persistence | Stage composition | A rejected allocation publishes no successful revision |
| [ProcessGeometry](../ProcessGeometry/DESIGN.md) | depends on | Exact dimensions, compatible source sites/orientations, reference ports | Process geometry authority | Retain pin identity and net while changing source-derived pose |
| [Package](../../../DESIGN.md) | used by | Placement wrapper and CLI | Public invocation | Geometry success cannot promote timing or production claims |

## Architecture

```text
Native executor -> source admission -> LegalPlacement allocator
    -> occupied intervals + aligned boundary events per row/orientation
    -> actual legal cells and pins -> output source admission -> retained artifacts
```

## Contracts and Invariants

- Rows and cells require positive, representable geometry and a core. Locked cells
  remain byte-equivalent values, placed on compatible rows, inside the core and
  outside blockages; overlapping locked cells fail before candidate search.
- Movable cells are processed by stable cell ID. Each cell searches all rows by
  stable row ID, retaining its incoming orientation first. With process sources,
  remaining standard orientations are tried only when exact master SIZE, symmetry
  and site compatibility admit them. Without sources only the supplied pose is
  available as geometry smoke, never process closure evidence.
- A candidate starts at the row origin or at an occupied interval's right boundary,
  aligned upward to the row site lattice. Blockages, locked cells and already
  allocated movable cells contribute actual rectangles. Placement spacing applies
  to newly allocated candidates relative to occupied cell bounds. Site-count-sized
  arrays and iteration over every site are not used.
- Candidate geometry must fit its row/core and avoid occupied rectangles. This is a
  deterministic incremental allocator, not a global optimal packing claim; failure
  reports that no candidate is available under the retained allocation order.
- Translation retains selected source pin offsets. Orientation changes reconstruct
  connected pins using exact source PORT geometry, retaining ID, cell ID, name and
  net ID. Pose changes invalidate stale routes, clock trees and dependent proofs.
- The automatic candidate ceiling is the checked structural bound
  `cellCount * rowCount * 8 * (blockageCount + cellCount + 1)`.
  `configuration.maximumPlacementCandidateChecks` is an optional positive caller
  ceiling; its effective value is the smaller of that ceiling and the structural
  bound. Omission selects the structural policy, not an arbitrary numeric default.
  Counts and the effective ceiling are exposed as raw placement metrics.
- Arithmetic overflow, exhausted candidate budget, cancellation and unavailable
  geometry are explicit failures. Neither an exhausted search nor a geometry
  observation establishes timing-driven or production closure. Successful geometry
  retains `timing: notApplicable` and `production: blocked`; characterized timing
  and production placement requests remain explicitly blocked by the executor.

## Runtime Flows

Admit exact state -> validate fixed occupancy -> derive ceiling -> allocate each
movable cell -> relocate/reconstruct pins -> validate real output geometry ->
retain JSON/DEF/diff/manifest. All candidate state is invocation-local; rejection
retains the input and publishes no successful revision.

## State, Ownership, and Lifecycle

The allocator and its protocol are Sendable immutable values. Candidate occupancy,
counters and output state belong to one invocation; no target-dependent shared
storage or isolation is introduced.

## Failure, Concurrency, and Constraints

Typed placement failures become structured blocked stage diagnostics. Cancellation
remains cancellation. Candidate event storage is bounded by occupied rectangles,
and candidate evaluations by the checked ceiling. Collision checking cost also
depends on supplied occupancy; no measured large-design throughput claim is made.

## Verification and Change Impact

LegalPlacement behavioral tests run actual native source intake and the CLI.
Counterexamples cover locked occupancy, a narrow legal site after a blockage and
an alternating-row orientation requiring source pin reconstruction. Rejections
cover capacity, explicit budget, invalid locked geometry, overflow and cancellation;
retained artifacts and exact process/pin/net identities are checked. Existing
placement/source-consumption regressions verify the shared native mutation path.
