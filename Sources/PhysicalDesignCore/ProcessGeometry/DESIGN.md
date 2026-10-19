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

- Construction consumes the shared [ProcessInputs antenna capability admission](../ProcessInputs/DESIGN.md#contracts-and-invariants)
  before mapping layers. Unmapped retained declarations cannot bypass admission.

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
- `routingWidthAndSpacing` is the shared source width authority. An explicit width
  keeps exact uniform semantics; an internal nil width derives the exact positive,
  even LEF WIDTH. Both enforce source MINWIDTH/MAXWIDTH and compiled spacing. The
  public selection and schema contract belongs to
  [TechnologyConstraints](../TechnologyConstraints/DESIGN.md#source-routing-width-policy).
- Routing queries own default WIDTH and compiled scalar/parallel-run-length spacing admission and cut overlap/edge spacing across expanded source PORT cuts and constructed contacts. RoutingGeometry owns candidate selection and conductor connectivity.
- Fixed vias retain each of the three distinct declared layer shapes and resistance.
  Typed canonical source layers and exact manifest mapping classify two ROUTING
  layers and one CUT; VIA LAYER statement order assigns no role. The routing layers
  use existing Native lower/upper ordering. Missing geometry or contradictory roles
  fail. Unused generation formulas remain retained nonexecuted source; generated
  VIA materialization remains unsupported.
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
- [RoutingGeometry](../RoutingGeometry/DESIGN.md#budgeted-fixed-via-selection)
  owns cumulative-budgeted legal selection among DEFAULT fixed masters. An explicit
  named master remains exact. The no-budget resolver validates named retained
  identity only and rejects unnamed selection. The centered contact, actual
  translated bounds and full caller spacing checks precede stable source-name selection.
- Selected fixed vias enforce the declared cut WIDTH and scalar edge-to-edge
  SPACING using the existing exact Manhattan/Euclidean geometry kernel. Distinct
  cut primitives cannot overlap; absent optional rules do not invent thresholds.
  `PhysicalDesignFixedCutSeparation` owns the shared primitive law: positive-area
  intersection fails, and a positive threshold compares actual polygon edge
  distances before any union can erase distinct cut identity. Edge/corner contact
  therefore fails positive SPACING. Candidate routing supplies its cumulative work
  admission before this synchronous, cancellation-aware check; retained catalogue
  validation consumes the same law.
- Both routing footprints cover every cut. Declared ENCLOSURE overhangs apply to
  opposite sides and may swap X/Y independently for each metal. The exact
  `enclosures` array is authoritative: BELOW applies below the CUT, ABOVE above,
  and an unqualified declaration applies to both. Applicable declarations are
  alternatives; each cut on each side must satisfy at least one applicable pair.
  No applicable pair adds no enclosure threshold beyond complete cut coverage.
  Rectangular cuts
  use exact expanded regions, including concave metal coverage; asymmetric
  enclosure of nonrectangular cuts remains unsupported when no applicable
  representable alternative proves satisfaction. Isotropic enclosure uses the
  existing polygon enclosure operation. Negative overhangs remain explicit
  unsupported values, without clamping; WIDTH/LENGTH/EXCEPTEXTRACUT contexts
  remain codec refusals.
- Qualified enclosure application resolves the adjacent routing layers from the
  selected technology LEF's bottom-to-top declaration order, required by
  [LEF 5.8](https://coriolis.lip6.fr/doc/lefdef/lefdefref/LEFSyntax.html#CutEnclosureDefinition).
  Exact manifest mapping identifies these layers; names and numeric parity do
  not establish vertical order. The classified fixed VIA routing pair must match those
  neighbors and the existing Native lower/upper ordering. Missing, ambiguous or
  contradictory source order fails. Unqualified-only legacy sources retain typed three-layer
  classification; their identical rule set applies independently to both sides.
- Admission checks inter-via cut overlap and source spacing, including same-net
  and redundant vias. This contact profile does not qualify full routing DRC.
- Every route, power rectangle, fill, track and clock route constraint resolves
  to a declared source ROUTING layer. Pin access uses the same check.
- Fill admission checks retained full conductor footprints, exact master PORT/OBS,
  fixed contact metal, each fill layer's own source clearance, existing fills and configured window
  fill-area ceilings. Source-free geometry uses only its explicit request-width
  smoke convention. No unknown source width is inferred for bound snapshots.
  The optional positive repair geometry ceiling lowers structurally finite work;
  exhaustion and cancellation reject the complete invocation-local candidate.
- Source-bound antenna repair supplies exact physical gate/diffusion declarations
  and named contact surfaces to [RepairMeasurement](../RepairMeasurement/DESIGN.md).
  Missing declarations fail; arithmetic ratio reduction and inferred next-layer
  numbers do not constitute feedback.
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

The invocation compiles spacing matrices once into immutable DBU axes and row-major
storage, preserving signed parallel-length thresholds and exact source references.
Lookup selects the last threshold strictly below each actual value, using the first
row/column as the standard minimum. Missing spacing is not inferred as zero.
[LEF 5.8](https://coriolis.lip6.fr/doc/lefdef/lefdefref/LEFSyntax.html) owns this rule.
RoutingGeometry owns actual object widths, projections and Euclidean separation.
Unqualified AREA thresholds are projected once to exact DBU-squared values.
Source routing owns bounded endpoint-extension repair and final connected routed
metal admission, using exposed PORT area only as a known lower bound. Abstract
cell views cannot qualify internal cell AREA DRC. CTS additionally owns the bounded candidate admission described below. Other
conductor mutation paths remain explicitly unsupported for AREA until they compose
their required final check.
Other unfinished process rules remain explicit unsupported capabilities.

Manufacturing-grid admission is owned by `PhysicalDesignManufacturingGrid`.
All explicit selected technology/cell grids must agree after exact positive DBU
conversion; nonrepresentable and contradictory declarations fail. Absence does
not invent a manufacturing grid. Source site/master dimensions, ORIGIN and
PORT/OBS/fixed-via vertices are checked before catalogue publication. Instance
transforms and actual route footprints, top-port rectangles, die/core, row/cell
bounds, power and fill rectangles are checked before and after mutation.
Route centerlines and pin access samples are not material vertices: half-grid
centerlines are legal when their complete qualified footprint is on-grid.
Unknown route width/extensions fail rather than inferring manufacturing legality.
Technology-only execution uses the same checker around mutation and before the
atomic persistence batch. Canonical JSON retains exact source references; resume
reconstructs the checker from those sources, never from caller metadata.

The immutable projection retains its output `unitsPerMicron` frame. ProcessInputs
resolves exact source DATABASE precision before projection. Binding or validating
a snapshot in another frame fails, including when its integer coordinates happen
to coincide. Source declarations remain immutable; inherited context is not written
back as a fabricated declaration into cell LEF facts.

The invocation resolves the source OBS width policy once. For ON, minimum routing
width (`MINWIDTH`, or declared default `WIDTH` when absent) is compiled into exact
DBU once per relevant PRL layer. OFF retains actual obstruction width. Missing
required width facts fail at use. Original OBS footprint, source identity and PRL
remain unchanged; PIN/fill/wire/blockage meanings are not inferred from net absence.

### Minimum enclosed hole area

Unqualified `MINENCLOSEDAREA` is distinct from metal-island `AREA`. Each selected
law must resolve to one canonical ROUTING layer and agree with that technology
source. Its square-micron value uses the existing exact DBU-squared conversion;
0.14 at 1000 DBU/micron is 140000 DBU squared. Absence invents no law.

```text
Exact selected law -> threshold by canonical layer
Snapshot PORT + routes + fixed VIA metal + power + fill -> material union bands
    -> complement inside union bounds -> enclosed components -> UInt64 hole area
    -> input admission / mutation / output admission / immutable publication
```

All source instance PORTs (including expanded PORT VIA metal), top PORT rectangles,
qualified full route footprints, translated fixed VIA routing shapes, power
rectangles and fill participate irrespective of net ownership. OBS, blockages,
cell bounding boxes and access-point samples do not assert metal. The rule checks
this retained physical material; abstract cell views do not prove unknown internal
cell metal or full-process signoff. A shape that fills another object's hole must
participate before comparison: per-primitive or per-net hole checks are incorrect.

The bounded rectilinear union kernel emits disjoint material bands. Complement
bands use Int64 endpoints within the original Int32 bounds, without a synthetic
`bbox +/- 1` frame. Existing positive-edge component connectivity and checked
UInt64 area accumulation distinguish enclosed holes from exterior components.
Components touching the union bounding box are exterior. Each enclosed area must
be at least its layer's threshold; solid metal and empty material have no hole.
Nonorthogonal/unqualified material, contradictory/unmapped laws, arithmetic
failure, caller work-ceiling exhaustion and cancellation fail explicitly.

Each admission pass owns one existing `PhysicalDesignRoutingWorkBudget` across all
hole layers. Its structural ceiling derives from admitted vertices/bands; the
optional request `maximumRoutingCandidateChecks` can only lower it. Collection,
union, complement, sorting, components and comparison charge this same counter.
The bounded compiler always honors Task cancellation. An internal supplemental
check can request cancellation after lower decomposition work; it cannot suppress
Task cancellation. The lower typed cancellation is translated to CancellationError
at this admission boundary. The immutable projection retains the request ceiling. No unbounded lower hole
operation or signed shoelace area is used. Independent pre/post passes revalidate
the actual snapshot rather than caching an input verdict as output evidence.

The Native executor consumes the request-aware ProcessInputs.requiresSourceGeometry(for:) and constructs
this projection when cell sources or retained hole laws exist, including
technology-only hole catalogues with no cell masters. Qualified fixed VIA
enclosure admission uses the same predicate, so the combined hole profile applies
both laws rather than retaining an obsolete absent-catalogue refusal.
Existing mutation pre/post admission therefore checks technology-only routes,
top PORTs, power and fill too. Technology-only sources without hole laws and
source-free smoke keep their existing paths. For a hole catalogue with neither
masters nor SITE declarations, an instance-free snapshot may retain the existing
request-owned unqualified row lattice. Nil SITE is not fabricated as a source
SITE or qualified placement evidence. Any actual instance still requires its
exact master and SITE admission; a present SITE keeps the strict row contract.
DEF keeps the existing unqualified row height carrier when SITE is absent;
qualified rows keep STEP-y zero. Canonical JSON retains this distinction for
resume. Standard DEF round trips do not qualify a synthetic site name. Manufacturing-grid checks
remain active before preparation and before publication. This composition does
not imply support for other retained process laws.

`MinimumEnclosedAreaTests` owns actual API/CLI below/equal/solid/empty cases,
merged material across owner types, exclusion of OBS/blockage, technology-only
admission, bounded work/cancellation/coordinate extremes, saved result decoding,
exact source references and unchanged-source resume. An opt-in original-source
case selects only the original met1/met2 `MINENCLOSEDAREA 0.14` statements into an
explicit fixture; it does not qualify the unmodified full PDK or its other rules.

### CTS connected metal area

CTS input and completed output admission evaluate the bounded layer-wide union of
known conductor material against each retained source `AREA` threshold. Components
are in scope only when they contain an actual route footprint, fixed VIA metal,
fill or power structure. Unchanged PORT-only components are a partial baseline,
not claimed as manufactured-cell AREA evidence. OBS, blockages and cell bounding
boxes are not conductor material.

```text
Source AREA + PORT lower bounds + actual route/VIA/fill/PG material
    -> bounded union bands -> connected components containing actual material
    -> sufficient known area: admit
    -> deficient complete island: invalid
    -> deficient component touching abstract macro PORT: unsupported/unproven
```

Exposed macro PORT shapes provide known lower bounds; they cannot reveal hidden
intrinsic cell metal. A known area at or above the threshold is sufficient. A
below-threshold component touching an abstract macro PORT is unproven, rather
than a definite manufacturing violation. Unconnected, fully observed deficient
islands fail as invalid geometry. Top-level PORT rectangles are fully observed.
This is candidate admission, not whole-cell/process qualification. Existing source
routing owns its bounded endpoint repair; CTS admission does not invent repair
or waive retained laws. The common Native pre/post stage boundary checks the
actual snapshot independently before publication. One caller-limited work budget
covers collection, union decomposition, connectivity and provenance comparison;
overflow, nonrectilinear geometry, exhaustion and cancellation fail explicitly.

[CTSAreaAdmissionTests](../../../Tests/PhysicalDesignEngineTests/CTSAreaAdmissionTests.swift)
owns isolated fill refusal, abstract PORT unproven refusal, union sufficiency,
budget/cancellation and Native API/CLI artifact truth. The ClockTreeSynthesis owner
owns original-source CTS positive fixtures; their retained AREA laws and source
PORT inventory remain unchanged.

## Routing Contact Pair Admission

`routingCutPairFits` borrows two canonical contact values and their already projected
shape buffers under one `PhysicalDesignRoutingWorkBudget`. RoutingGeometry owns
candidate selection, persistent history, and the contact arena that retains each
immutable shape buffer once. This predicate owns only the cross-contact cut test;
source PORT cuts, each master's intrinsic cuts, retained-contact admission and the
completed route's full cut replay keep their existing checks.

```text
Same ProcessGeometry + source/units + exact master/pose projection
    -> caller-owned immutable contact/shape arena -> borrowed contact pair
    -> declared identity and cut-presence check -> physical reuse or exact separation
```

- Both buffers must come from fixed-VIA projection for the supplied master and
  coordinates in this exact geometry invocation, source identity and DBU frame.
  They are trusted projected values, not an admission interface for caller-made
  shapes. The caller retains them through the borrow; no pointer escapes.
- Each contact must name a declared fixed master with matching lower/upper layers.
  The declared cut layer must remain a mapped CUT layer and both projected buffers
  must contain its actual cut primitives. Missing identities or cut data fail
  explicitly before any reuse or different-layer success; an empty pair is not a pass.
- Reuse means the same net, master, x/y and lower/upper routing layers. Canonical
  record ID and redundancy metadata do not change that physical identity. Different
  nets never reuse a coincident contact; different masters at the same position
  remain distinct contacts and undergo their actual cut overlap/spacing test.
- Distinct cut layers cannot violate the same-layer cut rule. Every primitive pair
  on one cut layer uses `PhysicalDesignFixedCutSeparation`, the existing exact
  overlap and edge-distance owner. There is no center-distance approximation or
  duplicated scalar law. Absent source SPACING retains the existing overlap-only
  contract; it does not invent a positive spacing threshold.
- The predicate adds no contact, shape or point arrays and performs no repeated
  projection. Ordinary owned/COW buffers supply the borrows. Existing lower Region
  intersection allocations remain part of the shared geometry kernel and are not
  described as allocation-free execution.
- One entry and every shape scan are charged. Before each primitive comparison,
  checked arithmetic admits trimmed vertex cost `n*m + n + m` to the same cumulative
  routing budget. Cancellation, invalid data, cost overflow and quota exhaustion
  propagate as failures. Arena storage ceilings remain RoutingGeometry-owned.

[RoutingCutPairTests](../../../Tests/PhysicalDesignEngineTests/RoutingCutPairTests.swift)
owns actual projected fixed-master pairs at below/equal/above edge spacing,
physical reuse versus foreign-net coincidence, different-master overlap,
missing master/cut data, caller quota and cancellation. RoutingGeometry owns the
history-sensitive search regression and completed-route replay. Changes to this
predicate must preserve both source admission and that caller's cumulative budget.

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

[QualifiedEnclosureTests](../../../Tests/PhysicalDesignEngineTests/QualifiedEnclosureTests.swift)
executes API and actual CLI cases for side selection, alternatives in both orders,
all-alternative failure, independently rotated asymmetric pairs, disjoint metal,
multiple cuts, missing/conflicting source order, unmapped and negative rules,
technology-only unvalidated fixed contacts and vacuous declarations. Positive
directional cases persist/reload exact JSON sources and resume through the same
API/CLI. The opt-in actual-source case retains the unmodified Sky130 nominal
`mcon` block through its enclosure pair before the next RESISTANCE statement,
and applies it to explicit synthetic test routing layers and fixed VIA geometry.
This proves that source law's application; it does not admit the full original
technology or claim antenna/current-density/process qualification.

Projection tests load digest-bound standard sources through ProcessInputs, then
verify asymmetric master ORIGIN under all eight orientations, concave polygons,
layer mapping, pin direction/use retention, OBS/site/fixed-via geometry, PORT VIA
expansion and exact source identities. Negative cases exercise missing/ambiguous
names, off-grid/range errors, invalid shapes and unsupported rule families.
Native mutation and persistence tests separately prove consumption of this contract.
They exercise real source intake, placement of asymmetric pins, schema round trips,
unchanged-source resume and changed/omitted-source rejection. Counterexamples cover
source size, direction, shape/layer, site/symmetry and via identity/footprint mismatches.

[ManufacturingGridTests](../../../Tests/PhysicalDesignEngineTests/ManufacturingGridTests.swift)
checks exact/sub-DBU/conflicting source grids, source PORT violations, input and
generated geometry rejection, legal half-grid centerlines, and real API/CLI
JSON/DEF readback and same-source resume, including technology-only requests.
The source-routing regression also executes grid-bound real PORT/via routing and
rejects generated off-grid metal from explicitly shifted tracks through API/CLI.
Source and output admission preserve cancellation as a cancelled outcome.

Source layer property capability is admitted by [ProcessInputs](../ProcessInputs/DESIGN.md)
before projection. That admission requires a mapped NWELL/PWELL subtype to remain MASTERSLICE and map
to a nonrouting PDK well-purpose layer. Raw property/subtype facts remain in the
immutable source catalogue. Classification does not substitute for well geometry,
well design rules, DRC, LVS or process qualification.


## Antenna Source Projection

`PhysicalDesignAntennaSourceProjection` owns immutable source facts, not numerical
antenna evaluation. NativeDRC remains the numerical owner. [Native executor composition](../NativePhysicalDesignExecutor.swift)
binds terminal definitions to snapshot pin occurrences and exact PORT record IDs
and lowers them through the RepairMeasurement adapter to the direct
[DRCNative/SourceAntenna](../../../../DRCEngine/Sources/DRCNative/SourceAntenna/DESIGN.md) contract. A source fact
must not use a net label or layer-wide conductor material as a connectivity proof.

The initial supported profile has one exact technology-role LEF, whose declared
ROUTING/CUT sequence defines fabrication rank. Every retained antenna layer has
one explicit compatible manifest mapping. Default or explicit OXIDE1 is supported;
other oxides and cell-role laws remain unsupported. Diffusion area laws use routing
surface or cut area; diffusion side-area laws require routing and finite positive
source THICKNESS. Scalar ratios are finite/nonnegative. PWL retains at least two
finite/nonnegative points with strictly increasing diffusion input. Numerical
interpolation is NativeDRC-owned and restricted to the inclusive knot domain;
source admission never invents extrapolation or clamps a diffusion value.

PIN facts use the existing strict-reader unqualified scalar abstraction and no
explicit PIN ANTENNAMODEL. Gate/diffusion values remain raw optional values and
retain exact artifact/master/pin identity. A missing or zero required input gate
is retained as missing-required-gate coverage, to be refused when that terminal
is requested for measurement. A missing PIN direction is unknown coverage and is
unsupported. Explicit positive gate area on any terminal is retained. Omitted
diffusion has reported contribution zero only under this complete unqualified
source abstraction; its raw nil and omitted-zero origin remain distinguishable
from an explicit source zero. No transistor, Liberty, or well-area inference is
performed. Other PIN/model abstractions remain unsupported until represented.

The projection verifies exact selected source references against manifest roles,
digests and byte counts. It admits source layers, statements, effective-law/PWL
records, master identities and terminal records before appending, under an explicit positive
maximumRecords supplied from the repair projection ceiling. Geometry/contact and
numerical work remain with their existing owners. Inputs and results are owned
Sendable values; arrays use ordinary value/COW ownership, with no shared mutable
state or unowned views. Before/after measurement can borrow the same source owner.

Source admission alone never marks PORT-only or unrouted geometry as an antenna
pass. Measured target admission requires exact terminal occurrence/net/PORT
coverage; a scalar terminal spanning multiple disconnected prefix components
remains unsupported. Stages without routed targets retain unassessed antenna
coverage. Unsupported profile, unknown coverage, invalid values, changed source
identity, exhausted projection records and cancellation fail explicitly.

`AntennaSourceProjectionTests` owns raw-absence versus explicit-zero provenance,
source-order/last-law/oxide semantics, unsupported coverage and exact record
quota/source-binding refusals. Existing Native capability API/CLI tests require
root-owned integration updates for the new source-admitted versus measured scope.
