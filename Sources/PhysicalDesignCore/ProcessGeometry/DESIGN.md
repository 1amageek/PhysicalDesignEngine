# Process Geometry

## Purpose and Scope

Project admitted standard views to exact native cell/pin/obstruction/site/via
geometry once per invocation. Parent: [PhysicalDesignCore](../DESIGN.md). No children.

## Responsibilities and Boundaries

Own mapped layers, exact geometry projection, source identity and fixed via stacks.
MasterGeometry owns required master dimensions. ProcessInputs owns source admission.
Native mutation owns access-point selection, placement, routing and output admission.
This projection alone does not establish native execution or process qualification.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent / used by | Native snapshot and request | Mutation input preparation | Output must be validated before persistence |
| [ProcessInputs](../ProcessInputs/DESIGN.md) | depends on | Admitted LEF views and exact DBU | Shared source intake | No file reread or name-based asset selection |
| [MasterGeometry](../MasterGeometry/DESIGN.md) | depends on | Required unique master SIZE | Cell bounds | No default dimensions |
| [DEF Interchange](../../../../swift-mask-data/Sources/DEF/Interchange/DESIGN.md) | depends on | Standard orientation to IR transform | Exact rotation/reflection | Engine normalizes lower-left placement |
| [MaskGeometry](../../../../swift-mask-data/DESIGN.md) | depends on | Region and exact rectilinear operations | Existing shape representation | Reject nonrectilinear geometry explicitly |

## Architecture

```text
Exact manifest + selected LEF views -> explicit cross-view layer/master mapping
    -> one DBU projection of sites / fixed vias / master pin and OBS shapes
    -> checked ORIGIN + standard orientation + placement transform
    -> native preparation and output checks
```

## Contracts and Invariants

- Native shapes reuse LayoutIR boundaries and MaskGeometry regions. Coordinate
  conversion and transformed positions must fit Int32; native physical inputs
  outside this geometry backend range fail explicitly rather than narrowing.
- Each referenced layer resolves exactly once through the selected asset's explicit
  cross-view layer IDs and canonical names/aliases. No M-number or parity inference.
- Cell source MACRO names must be explicitly mapped and unique. SIZE is positive
  and exact on the snapshot DBU grid. Pin names, sites and via names are unique.
- Pin and OBS RECT/POLYGON geometry is retained by layer. Empty, off-grid,
  nonrectilinear, degenerate or self-intersecting polygons fail. MASK semantics
  remain unsupported until mask-aware native rules are implemented; they fail.
- LEF ORIGIN is added before the standard orientation. Rotation/reflection uses
  the common DEF mapping. The transformed SIZE lower-left corner is normalized
  to the canonical placement location; pins outside SIZE remain outside.
- Fixed vias retain each of the three declared layer shapes and resistance.
  The source stack requires routing/cut/routing layers, with explicit canonical
  numbers compatible with native lower/upper ordering. Missing geometry or
  mismatched cut-layer semantics fails. Generated via rules remain explicit
  unsupported until their complete standard parameters are available.
- PORT VIA references expand the exact fixed via shapes at their declared local
  positions; missing definitions or mismatched source layer identity fails.
- Source manifest and asset content references are retained for exact resume checks.
  The catalogue is transient; it is not a second canonical database or file cache.

## State, Ownership, and Lifecycle

One invocation owns immutable projected masters/sites/vias. Boundary point buffers
are materialized once per source projection. Placement transforms materialize only
required instance geometry at the native/output boundary; no byte reread or shared
mutable state is introduced.

## Failure, Concurrency, and Constraints

Conversion is bounded by admitted view counts, artifact sizes, declarations and
vertices. Polygon validity checks and the existing rectilinear geometry kernel
have vertex-dependent cost; profile/runtime budgets and measurements remain B10.
All unsupported semantics and coordinate overflow produce typed failures before
publishing geometry. Production capability remains blocked independently.

## Verification and Change Impact

Projection tests load digest-bound standard sources through ProcessInputs, then
verify asymmetric master ORIGIN under all eight orientations, concave polygons,
layer mapping, pin direction/use retention, OBS/site/fixed-via geometry, PORT VIA
expansion and exact source identities. Negative cases exercise missing/ambiguous
names, off-grid/range errors, invalid shapes and unsupported rule families.
Native mutation and persistence tests separately prove consumption of this contract.
