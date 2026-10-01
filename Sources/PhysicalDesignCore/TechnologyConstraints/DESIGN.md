# TechnologyConstraints

## Purpose and Scope

Prepare process-bound routing constraints for native geometry execution.
Parent: [PhysicalDesignCore](../DESIGN.md). No children. This is a scalar technology
LEF subset; pin access, via stacks, advanced spacing and process qualification remain incomplete.

## Responsibilities and Boundaries

This component owns exact technology binding, DBU conversion, layer projection and
track preparation. PDKKit owns manifest decoding; the fixed LEF product owns parsing.
The native mutation engine owns routing and grid admission.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PhysicalDesignCore](../DESIGN.md) | parent / used by | Snapshot and artifact store | Executor input preparation | Preserve original snapshot for diff generation |
| [PDKKit](../../../../PDKKit/DESIGN.md) | depends on | PDKManifestCodec, manifest values | Exact process/layer identity | Do not infer layer numbers from names |
| [swift-mask-data](../../../../swift-mask-data/DESIGN.md) | depends on | LEFLibraryReader, LEFTokenizer | Scalar technology view | Preflight rejects discarded multi-value/spacing semantics |

## Architecture

```text
technology/LEF input bindings + PDK manifest binding
    -> verified bytes -> manifest identity + declared asset digest/size + layer mapping
    -> LEF scalar constraints -> integer DBU -> validate or generate tracks
```

## Contracts and Invariants

Only input bindings with kind `technology` and format `lef` activate this path.
Absence preserves the existing geometry-smoke path for snapshots without technology
provenance. Prepared snapshots retain technology content IDs in metadata; later
stages must supply technology bindings again. Dropping those bindings must fail.
Every consumed binding must be retained in request provenance. Presence cannot fall back to
synthetic constraints. Each supplied LEF must match exactly one manifest technology
asset by SHA-256 and byte count; its LEF cross-view mapping must include each used
canonical layer. The decoded manifest process/version and retained digest must
match the request. Configured layer numbers map directly to unique routing-layer
definitions; name/alias matching is exact and unambiguous. Canonical layer IDs and
LEF layer names cannot be reused by another configured layer.

Required LEF values are direction, scalar pitch, offset, width and base spacing.
Offset is required rather than inferred. Non-finite, negative, missing or
non-representable values fail. Micron values are scaled by snapshot units; nearest
integer DBU is admitted only within one floating-point ULP and below 2^53, retaining
integer precision. Width must satisfy MINWIDTH/default WIDTH and optional MAXWIDTH;
configured spacing must satisfy base SPACING. Two-axis PITCH/OFFSET, qualified
SPACING and SPACINGTABLE are unsupported and explicitly fail before projection.

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

Input length is bounded by retained artifact size. Parser/preflight storage is linear
in input bytes; each view is read once, with token preflight required because the
existing public reader otherwise drops needed scalar constraints. Layer/track work
is bounded by supplied views and configured layers, not track count. Cancellation is
checked between views. Semantic errors are typed; failed preparation emits no revision.

## Verification and Change Impact

[TechnologyConstraintsTests](../../../Tests/PhysicalDesignEngineTests/TechnologyConstraintsTests.swift)
owns source identity, exact conversion, malformed/unsupported views, explicit-track
compatibility and persisted track values. Native stage tests own grid admission.
Recheck executor provenance/CLI handoff when binding semantics change; changes to
PDK or parser contracts require renewed source-path review before updating the dependency.
