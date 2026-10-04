# TechnologyConstraints

## Purpose and Scope

Prepare process-bound routing constraints for native geometry execution.
Parent: [PhysicalDesignCore](../DESIGN.md). No children. This is a routing-grid technology
LEF grid subset. RoutingGeometry owns source pin access and fixed contacts; advanced rules and process qualification remain incomplete.

## Responsibilities and Boundaries

This component owns DBU conversion, layer projection and track preparation.
[ProcessInputs](../ProcessInputs/DESIGN.md) owns exact source admission and parsing.
The native mutation engine owns routing and grid admission.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PhysicalDesignCore](../DESIGN.md) | parent / used by | Snapshot and artifact store | Executor input preparation | Preserve original snapshot for diff generation |
| [RoutingGeometry](../RoutingGeometry/DESIGN.md) | coordinates with | Scalar source clearance selection | Source-bound routing admission | Routing owns max(source SPACING, caller clearance) |
| [ProcessInputs](../ProcessInputs/DESIGN.md) | depends on | Admitted manifest and technology views | Shared parsed inputs | No repeated read or parsing |
| [PDKKit](../../../../PDKKit/DESIGN.md) | depends on | PDKManifestCodec, manifest values | Exact process/layer identity | Do not infer layer numbers from names |
| [swift-mask-data](../../../../swift-mask-data/DESIGN.md) | depends on | LEFLibraryReader, shared typed axis values | Exact technology routing view | Common codec rejects unretained grammar; engine rejects unsupported rules |

## Architecture

```text
ProcessInputs admitted manifest and technology views
    -> explicit asset ID cross-view layer mapping
    -> LEF typed constraints -> select track axis -> integer DBU -> validate or generate tracks
```

## Contracts and Invariants

Technology views admitted by ProcessInputs activate this path. Absence preserves
geometry-smoke only for snapshots without retained technology provenance. Later
stages must supply the same explicit source asset map through request and run
manifest `processAssets`, including availability. Each view's manifest cross-view
mapping must include every configured canonical routing layer. Configured layer numbers map directly to unique routing-layer
definitions; name/alias matching is exact and unambiguous. Canonical layer IDs and
LEF layer names cannot be reused by another configured layer.

Required LEF values are direction, pitch, offset, width and base spacing.
Scalar declarations apply to either axis. Two-axis declarations use Y for
horizontal tracks and X for vertical tracks, including offset. The unused axis
is retained by the standard schema; it is not silently substituted for the selected axis.
Offset is required rather than inferred. Non-finite, negative, missing or
non-representable values fail. Micron values are scaled by snapshot units; nearest
integer DBU is admitted only within one floating-point ULP and below 2^53, retaining
integer precision. Width must satisfy MINWIDTH/default WIDTH and optional MAXWIDTH;
configured spacing must satisfy base SPACING outside source-bound global/detailed routing and selected-net ECO rerouting. Those routing paths retain the source value and let RoutingGeometry select the greater of source SPACING and caller clearance. Qualified SPACING is rejected by
the common codec; SPACINGTABLE is retained by the codec but unsupported by this
native routing profile and explicitly fails before mutation.

Generated track positions use the LEF offset's global grid, begin at the first
grid point inside the core and stop before its upper bound. Explicit tracks are
preserved only if selected layers have matching direction, pitch and global-grid
phase, with non-overflowing last coordinates. Missing selected coverage fails.
Track origin/count differences are allowed because imported DEF tracks can cover
the die rather than only the core.

## Runtime Flows

Load snapshot -> prepare technology -> native mutation -> validate output -> persist.
For floorplan only, derive the same proposed core as floorplan when none exists;
checked coordinate arithmetic must fail before mutation on invalid geometry.

## State, Ownership, and Lifecycle

Input bytes and parsed values are owned by one invocation. The store supplies exact
content bytes; no filesystem path is opened outside its contract. Prepared tracks
enter the snapshot; original loaded state remains the diff baseline. Source bindings
remain in run provenance. No persistent cache or shared mutable state is introduced.

## Failure, Concurrency, and Constraints

Input length is bounded by retained artifact size. Parser storage is linear
in input bytes; ProcessInputs reads and parses each selected view once; this consumer does not
repeat source admission or tokenization. Layer/track work
is bounded by supplied views and configured layers, not track count. Cancellation is
checked between views. Semantic errors are typed; failed preparation emits no revision.

## Verification and Change Impact

[TechnologyConstraintsTests](../../../Tests/PhysicalDesignEngineTests/TechnologyConstraintsTests.swift)
owns source identity, exact conversion, malformed/unsupported views, explicit-track
compatibility and persisted track values. Native stage tests own grid admission.
Recheck executor provenance/CLI handoff when binding semantics change; changes to
PDK or parser contracts require renewed source-path review before updating the dependency.
