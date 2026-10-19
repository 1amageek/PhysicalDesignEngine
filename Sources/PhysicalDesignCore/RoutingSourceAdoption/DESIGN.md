# RoutingSourceAdoption

## Purpose and Scope

Create an explicitly checked new input revision when a retained physical candidate
adopts an extended routing technology view. Parent:
[PhysicalDesignCore](../DESIGN.md). No children. This operation does not route,
publish artifacts, grant source qualification or reinterpret the parent's identity.

## Responsibilities and Boundaries

`PhysicalDesignRoutingSourceAdopting` reads exact parent/source bindings through the
existing `PhysicalDesignArtifactStore` protocol. `NativePhysicalDesignRoutingSourceAdopter`
uses ProcessInputs and ProcessGeometry for source admission. It owns preservation
checks and lineage, not LEF parsing, routing laws, host files or artifact publication.
The caller saves the returned snapshot as a fresh immutable input artifact and
constructs the routing request with that new inputLayout reference.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [PhysicalDesignCore](../DESIGN.md) | parent | Typed snapshot/reference/store | No completed candidate publication here |
| [ProcessInputs](../ProcessInputs/DESIGN.md) | depends on | Exact asset/manifest LEF admission | Original bytes remain authoritative |
| [ProcessGeometry](../ProcessGeometry/DESIGN.md) | depends on | Bound source projection and whole geometry validation | Normal bind still rejects source changes |
| [TechnologyConstraints](../TechnologyConstraints/DESIGN.md) | depends on | Checked source-extension track preparation | Keep every old track unchanged |
| [RoutingGeometry](../RoutingGeometry/DESIGN.md) | used by | Fresh source-bound routing input | No joint routability guarantee |

## Architecture

```text
exact parent + old request + new request + explicit limits
  -> bounded typed-store reads -> old/new ProcessInputs
  -> old typed facts subset + unchanged cell assets/layer identities
  -> old and new whole geometry admission
  -> source-owner track extension + stale evidence invalidation
  -> checked non-Codable result -> caller saves NEW input artifact
```

## Contracts and Invariants

Both requests name the exact parent inputLayout and the same logical design,
constraints, process ID and version. The old parent retains its original manifest,
assets and content identity. The initial profile keeps asset IDs and all cell-role
source references unchanged while allowing technology-role asset replacement.
Old canonical layer definitions, including native number/name/role, must remain
identical; new layers use unused positive native numbers and distinct layer IDs.

Typed LEF subset checking owns preservation: all old nonnil grid/routing/cut,
spacing/PRL, width, AREA/hole, enclosure, R/C and density facts retain the same
values; old property/antenna/current statements remain included; old sites and
fixed VIA definitions are identical. Added constraints are not discarded: new
ProcessGeometry validates the complete existing geometry under the extended view.
Cell bytes/PORT/OBS, entities, poses and retained routes/VIA geometry are unchanged.
No source is stripped or normalized to manufacture support. Actual original-source
byte ranges can accompany fixture provenance but verbatim concatenation is not a
generic authorization condition.

New configured routing layers receive tracks from exact source direction,
pitch/offset and core through TechnologyConstraints. Every supplied old track is
preserved and revalidated; normal prepare/bind source-change refusal is unchanged.
Old clock timing estimates, placement/routing/repair proofs are invalidated while
clock-tree physical topology and clock route constraints remain intact.

Result construction is internal, its snapshot/lineage fields are read-only, and
the result is not Codable. Codable lineage alone grants no checked-adoption
authority. Snapshot metadata `routingSourceAdoptionLineage` contains that same
typed lineage JSON and `clockTimingStatus` discloses invalidation. The caller
retains the exact parent and old/new full source references before API/CLI routing.

## State, Ownership, and Lifecycle

The implementation is stateless and Sendable. Read buffers and parsed source
contexts are call-local; retained value buffers use their existing COW ownership.
The result owns the new snapshot. Existing input artifacts are read only.

## Failure, Concurrency, and Constraints

Explicit caller limits bound the combined parent plus old/new manifest/source
byte counts before any whole read, source asset counts, and parsed source entries
before geometry projection. A call-local forwarding actor requires the store's
bounded-read capability for every parent, manifest and LEF read, including reads
performed by ProcessInputs. Each read is capped at that exact reference's byte
count and debited before suspension from the cumulative caller allowance; stores
without this capability explicitly refuse adoption. Declared counts alone do not
authorize unbounded reads. Duplicate old/new assets count twice in the logical
buffer bound because both contexts can coexist. This accounts for whole-read
buffers and both parsed contexts as logical input bounds, not an allocator/RSS
guarantee. Source-entry limits cover layers, sites, masters, pins, shapes and
vertices; cancellation is checked through scans and existing source owners.
Public typed adoption errors retain reason/message and original cause; task
cancellation remains CancellationError. Unsupported or changed source facts never
become a successful revision or an implicit fallback.

## Verification and Change Impact

[RoutingSourceAdoptionTests](../../../Tests/PhysicalDesignEngineTests/RoutingSourceAdoptionTests.swift)
owns positive extension, old-fact mutation, foreign parent, unsupported source,
native layer collision, changed grid, caller limits/cancellation, lineage reload
and normal old-binding refusal. Actual full-six-layer API/CLI candidate routing,
DEF/proof/reload and original source provenance belong to
`ActualSky130DetailedRoutingTests`; this component's success does not replace those
integration results or establish whole-PDK/EM/density qualification.
