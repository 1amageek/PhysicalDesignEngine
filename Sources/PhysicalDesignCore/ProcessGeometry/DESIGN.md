# Process Geometry

## Purpose and Scope

Project admitted standard views to exact native cell/pin/obstruction/site/via
geometry once per invocation. Parent: [PhysicalDesignCore](../DESIGN.md). No children.

## Responsibilities and Boundaries

Own mapped layers, exact geometry projection, source identity, fixed via stacks
and source-bound canonical geometry admission before and after mutation.
MasterGeometry owns required master dimensions. ProcessInputs owns source admission.
Native mutation owns access-point selection, placement and routing. Source admission
does not establish route closure, timing closure or process qualification.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [RoutingGeometry](../RoutingGeometry/DESIGN.md) | used by | PORT/OBS/layer/fixed-contact projection | Actual routing geometry | Candidate selection and conductor contact proof belong to routing |
| [LegalPlacement](../LegalPlacement/DESIGN.md) | used by | Exact SIZE, source symmetry/site and reference pins | Candidate source poses | Allocation retains pin/net identity and final source admission |
| [ClockTreeSynthesis](../ClockTreeSynthesis/DESIGN.md) | used by | Exact canonical master-point orientation/placement projection | Explicit CTS electrode faces | Face selection is caller-owned; projection cannot select an electrical boundary |
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
- Routing queries own scalar default WIDTH/SPACING admission and cut overlap/edge spacing across expanded source PORT cuts and constructed contacts. RoutingGeometry owns candidate selection and conductor connectivity.
- Fixed vias retain each of the three declared layer shapes and resistance.
  The source stack requires routing/cut/routing layers, with explicit canonical
  numbers compatible with native lower/upper ordering. Missing geometry or
  mismatched cut-layer semantics fails. Generated via rules remain explicit
  unsupported until their complete standard parameters are available.
- PORT VIA references expand the exact fixed via shapes at their declared local
  positions; missing definitions or mismatched source layer identity fails.
- Source manifest and asset content references are retained for exact resume checks.
  The catalogue is transient; it is not a second canonical database or file cache.
- Snapshot schema 2 retains exact manifest/asset references, standard cell orientation,
  optional pin access layer, optional row site name/orientation, optional fixed-via
  master and optional conductor width. Optional fields support explicitly unqualified geometry smoke inputs; a
  process-bound snapshot requires every referenced process meaning to be resolved.
- Resumption requires the same manifest and full asset-ID/reference map. Omitting or
  substituting a source cannot downgrade a process-bound snapshot to geometry smoke.
- Cell dimensions equal oriented source SIZE. Pins use declared direction and a
  declared routing-layer shape containing the selected point. Coordinates remain
  instance-global; translation during placement preserves the exact local geometry.
- Rows reference source sites with exact oriented dimensions. Placed core cells
  must occupy a compatible site and lie on its lattice; relative row/cell orientation
  must match site symmetry while the global orientation is a master symmetry
  candidate, following the [LEF standard symmetry contract](https://coriolis.lip6.fr/doc/lefdef/lefdefref/LEFSyntax.html).
  Row orientation itself is not restricted by site symmetry: Y-symmetric sites
  admit N/FN cells in N rows and FS/S cells in FS rows with X/Y master symmetry.
  Non-core placement profiles fail explicitly.
- Vias reference fixed source masters and matching layer pairs; translated footprints
  must fit the die. Fabricated inserted/resized cells and unnamed vias fail output
  admission rather than becoming persisted successful revisions.
- Native construction resolves exactly one DEFAULT fixed via for the declared layer
  pair, or preserves an explicit existing source master. The center-joined profile
  admits only routing footprints containing the origin and full translated shapes
  inside the construction bounds. Missing/ambiguous defaults and offset-access
  profiles fail explicitly.
- Selected fixed vias enforce the declared cut WIDTH and scalar edge-to-edge
  SPACING using the existing exact Manhattan/Euclidean geometry kernel. Distinct
  cut primitives cannot overlap; absent optional rules do not invent thresholds.
- Both routing footprints cover every cut. Declared ENCLOSURE overhangs apply to
  opposite sides and may swap X/Y independently for each metal. Rectangular cuts
  use exact expanded regions, including concave metal coverage; asymmetric
  enclosure of nonrectangular cuts fails explicitly. Isotropic enclosure uses
  the existing polygon enclosure operation. Unsupported qualified/repeated rules
  are rejected by strict LEF intake, including nondefault clearance metrics.
- Admission checks inter-via cut overlap and source spacing, including same-net
  and redundant vias. This contact profile does not qualify full routing DRC.
- Every route, power rectangle, fill, track and clock route constraint resolves
  to a declared source ROUTING layer. Pin access uses the same check.
- Source-bound antenna repair fails before mutation or publication until the
  native source-qualified calculation can remeasure a candidate. Arithmetic
  ratio reduction and inferred next-layer numbers do not constitute feedback.
- Public bare mutation cannot consume bound process sources without the artifact
  intake path. The executor supplies the immutable projection to internal mutation.
- Connected pin reconstruction reuses one deterministic declared routing-boundary
  reference point for DEF intake and explicit master replacement. Identity and net
  connectivity remain caller-owned; coordinates, direction and layer come from the
  selected source port. This point does not prove wire-width-aware legal access.
- The buffer source profile requires exactly one input and one output signal/clock
  port, excluding power/ground ports. Actual port names and poses drive native
  insertion; extra control/inout ports fail explicitly. This physical interface
  does not establish the selected master's logical function or timing closure.
- The returned physical reference identifies canonical JSON, retaining all state and
  process references. DEF is an interchange artifact with its own bounded semantics,
  not a lossless resume authority.
- DEF export requires a valid snapshot and explicit die. The current process-bound
  floorplan/cell subset emits exact source layer/site names, orientations and FIXED
  status without synthetic cell-dimension properties. RoutingGeometry owns bounded
  normal-net default-width/named-contact export. Exact top-port export uses [TopPorts](../TopPorts/DESIGN.md). Finite special-route export uses [RoutingGeometry](../RoutingGeometry/DESIGN.md); advanced special-net export and
  routed import remain unsupported until their standard contracts are established.

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
They exercise real source intake, placement of asymmetric pins, schema round trips,
unchanged-source resume and changed/omitted-source rejection. Counterexamples cover
source size, direction, shape/layer, site/symmetry and via identity/footprint mismatches.
