# Top Ports

## Purpose and Scope

Own exact canonical top-level single-rectangle port values and their integer DBU
placement. Parent: [Core](../DESIGN.md). No children. Cell-library ports remain
owned by ProcessGeometry; this component does not reinterpret them.

## Responsibilities and Boundaries

A top-level Pin owns name, net and direction. Its immutable PhysicalDesignTopPort
owns the declared local rectangle, mapped routing layer, placement origin,
orientation, placement status and use. The enclosing snapshot owns DBU scale and
exact process references. Retained input DEF or caller-owned canonical state is
port authority; points, route widths and floorplan pads never generate its shape.

## Related Designs

| Design | Relationship | Contract Used | Cautions |
|---|---|---|---|
| [Core](../DESIGN.md) | parent | Snapshot and validation | Canonical JSON is resume authority |
| [ProcessGeometry](../ProcessGeometry/DESIGN.md) | used by | Exact routing-layer mapping and process admission | No inferred layer or metal |
| [RoutingGeometry](../RoutingGeometry/DESIGN.md) | used by | Exact surface as terminal PORT and occupancy | Existing width/track/search budgets remain unchanged |
| [StandardLayoutExport](../StandardLayoutExport/DESIGN.md) | used by | Bounded native DEF publication | Route semantics belong to RoutingGeometry |
| [Physical database schema](../../../../PhysicalDesignDatabaseIntegration/Sources/PhysicalDesignDatabaseSchema/DESIGN.md) | used by | Lossless value/codec/page retention | Missing required geometry is rejected |

## Architecture

```text
retained DEF RECT / canonical typed value + snapshot DBU/process identity
    -> immutable local rectangle and exact pose
    -> checked orthogonal world rectangle / explicit access point
    -> process mapping and net membership admission
    -> shared native producer / public bounded DEF exporter
    -> exact canonical database bytes and immutable pages
```

## Contracts and Invariants

- Source-bound cellID=nil pins require a topPort; cell pins cannot carry one.
- The supported surface is one positive single-layer rectangle. All eight DEF
  orientations transform around the declared placement origin, without macro-frame
  normalization. Local and transformed coordinates fit the native Int32 geometry
  backend, and arithmetic is checked before negation, addition or extent formation.
- Pin accessLayer equals the port layer and its explicit access point is inside
  the transformed surface. DEF intake uses the declared placement origin when inside the actual surface,
  otherwise its exact world minimum corner. This integer point is derived access
  metadata, not wire endpoint authority. Odd-DBU rectangles remain supported.
  Export retains the original placement separately from access coordinates.
- NET, DIRECTION, USE and placed/fixed/cover status are explicit. Source-bound pins
  are members of exactly their declared canonical net. Missing fields, multiple
  rectangles/layers, mask qualification, polygons and unsupported attributes fail
  rather than supplying defaults. Process-bound routed/special-net intake remains
  separately unsupported.
- Values are copied into canonical snapshots and retained bytes; no external pointer,
  shared state, mutable cache or Foundation/database dependency is introduced here.

## State, Ownership, and Lifecycle

Ports are immutable Sendable values owned by the snapshot. Integer projection is
invocation-local. The native executor owns retained input and output artifacts;
the host database owns immutable canonical revisions and their retention policy.

## Failure, Concurrency, and Constraints

Malformed geometry, overflow, missing semantics and unsupported profiles are
explicit typed projection errors or structured DEF admission diagnostics. Source
geometry does not silently fall back to point/pad/default-width representations.

## Verification and Change Impact

[TopPortInterchangeTests](../../../Tests/PhysicalDesignEngineTests/TopPortInterchangeTests.swift)
executes real native source-bound producer/public export pairing, standard DEF
roundtrip, all poses and geometry/net/source failure cases. The host schema tests
verify canonical codec/page retention and geometry-dependent content identity.
Changes affect ProcessGeometry admission, the native writer/parser and database
canonical payload; LayoutIO GDS port interpretation remains its own contract.
