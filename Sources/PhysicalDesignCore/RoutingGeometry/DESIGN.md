# Routing Geometry

## Purpose and Scope

Own bounded source-bound native signal routing, finite special-net routing and selected-net ECO rerouting.
Parent: [PhysicalDesignCore](../DESIGN.md). No children. Existing stage wrappers
compose this responsibility directly; CTS and production qualification are separate.
Ordinary routing excludes CTS-owned root/branch net families and preserves their
exact routes, contacts and topology. Geometry changes invalidate old timing
observations because CTS extraction captures other conductors as well. Explicit selection of a
CTS-owned net refuses until CTS owns reroute/recharacterization. Synthetic power
grid structures remain unsupported. Finite special-net point-to-point routing
does not synthesize a power grid.

## Responsibilities and Boundaries

ProcessGeometry owns exact PORT/OBS, layer and fixed-contact projection. This
component selects access locations and materializes actual conductors and vias.
The executor owns exact input intake and atomic immutable output publication.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent / used by | Routing stage composition and canonical state | Actual routing branch | Source-free geometry smoke remains a separate incomplete branch |
| [ProcessGeometry](../ProcessGeometry/DESIGN.md) | depends on | Exact transformed regions, source layers and fixed via contacts | Geometry authority | No inferred process defaults or pin layers |
| [TechnologyConstraints](../TechnologyConstraints/DESIGN.md) | depends on | Exact declared track phase, pitch, count and direction | Finite grid | Track count does not authorize whole-site enumeration |
| [Package](../../../DESIGN.md) | used by | API/CLI and retained JSON/DEF | Public invocation | Timing and production are independently blocked |
| [DEF](../../../../swift-mask-data/Sources/DEF/DESIGN.md) | depends on | Standard normal-net wire/via grammar | Bounded export oracle | Not foundry qualification or canonical resume authority |

## Architecture

```text
Exact source admission -> actual PORT/OBS/layer/via regions + declared tracks
    -> boundary events -> source-static legal event graph -> reverse distances
    -> bounded contact-history search
    -> conductors + named fixed contacts + selected access points
    -> geometric/connectivity checks -> JSON/DEF/diff/manifest atomic publication
```

## Contracts and Invariants

- Routing retains cell geometry and net/pin identity. Every terminal has an exact
  component PORT, explicit selected routing layer and matching net membership.
  Top-level point ports cannot substitute for source area and fail explicitly.
- Each conductor retains positive `widthDBU` on its canonical RouteSegment.
  Source-bound routing requires width on retained conductors; an absent width is
  unqualified geometry, never silently interpreted using the new request.
- The regular-net integer-geometry profile uses even DBU widths matching the selected layer's
  declared LEF WIDTH exactly. Missing WIDTH, nondefault regular widths, wrong-way wires and
  unfinished rule semantics fail. Effective scalar conductor clearance is the greater
  of source SPACING (when present) and caller routeSpacing.
- Standard normal NETS uses the declared default width. Native wire construction
  explicitly chooses half-width endpoint extensions; retained geometry follows the
  exact ordered extension contract below.
  A chosen access cap must be wholly contained in the exact PORT union on its
  selected layer; point containment or corner-only contact does not prove access.
- Every segment lies on a declared track of its layer/direction and fits the core.
  Blockages exclude their actual areas. Layer-specific OBS, unrelated PORTs,
  retained other-net conductors, fill and via metal exclude conductor geometry with
  effective clearance. Same-net conductors may join through positive area.
- Transitions choose an eligible admitted DEFAULT fixed via for the pair through the shared budgeted selector. All metal
  and cut footprints fit construction bounds and avoid excluded geometry. Actual
  source cut overlap/edge spacing is checked for expanded PORT cuts and all
  contacts, including same-net contacts. Cut OBS and excluded PORT footprints
  also reject translated contacts. Repair center-distance estimates cannot substitute for cut geometry.
- Connections are deterministic in stable net/pin order. A lazy search uses finite
  coordinate events from core/PORT/obstacle boundaries, conductor/via extents and
  adjacent declared track locations. It never enumerates every track/site.
  Exhausting the admitted work or history allowance is a typed resource refusal.
  Only a drained frontier establishes no legal continuation among the admitted
  labels; neither result claims global routing completeness or optimality.
- Event-derived access and search allowances remain finite operational admission
  limits. For P terminals, L eligible layers, X/Y coordinate events and V eligible
  DEFAULT masters, access admission uses `P*X*Y*L*max(1,V)` and search-label admission
  uses `(P-1)*L*X*Y*(L+3)*max(1,V)`, with checked arithmetic. These allowances bound
  admitted access and aggregate label entries. Contact and nonempty history
  arenas each have the checked sum of those two allowances as an independent
  growth limit; each contact's shape/vertex storage is charged before retention.
  Target-node buckets contain only the already bounded terminal accesses.
  These limits do not prove that every possible contact history fits the allowance. The caller's positive `maximumRoutingCandidateChecks`, when
  supplied, remains the cumulative work ceiling and is never raised implicitly.
  Label, history, contact/shape, visited/bucket and queue growth is admitted before
  allocation. Chain traversal, exact-set equality, sorting and cut probes consume
  the same invocation-owned budget. Access probes reserve the finite access allowance;
  search probes admit their known cost before each operation under the independent
  aggregate label cap. Each label has at most L+2 neighbor attempts. The old
  node-only search reservation cannot bound the new distinct-history work.
  Budget exhaustion is resource refusal, not a
  claim that the physical layout or every history in the event domain is unroutable.
- Arithmetic/backend range errors, missing semantics, exhausted budgets, unavailable
  access/path and cancellation are explicit blocked/cancelled results. Failed
  searches retain no partial successful revision or fabricated connectivity.
- Canonical JSON retains widths, selected access coordinates, layer/net identity,
  named vias and exact process bindings. Unselected routes/vias are preserved.
- Bounded source-bound DEF output represents normal-net default-width segments and
  named fixed contacts using exact layer names and standard routing points. NDR,
  advanced special-net geometry and source-bound routed DEF import remain
  typed unsupported. Canonical JSON is the resume authority.

## Runtime Flows

Source admission -> validate profile and fixed occupancy -> derive events/ceiling
-> qualify static event edges -> target reverse distances -> connect terminal PORTs -> retain actual geometry -> final source/contact checks
-> complete immutable artifact batch -> completed result. Publication failures do
not claim completion. Geometry completion keeps timing notApplicable and production
blocked; characterized timing and production routing requests remain unsupported.

Parallel-run-length tables use maximal axis-aligned rectangles contained in the
exact orthogonal union, signed projected overlap and the greater local width.
Neither the union bounding box nor scanline slab height substitutes for width.
Rectangles and exposed directed boundary edges are compiled once per exact
occupancy object; unchanged objects retain their facts, and combining metal creates
a new object. Candidate wire/cap/contact geometry uses the same immutable rule. Rectangle
fracture faces do not establish spacing: the gap must contain the corresponding
real outward-facing polygon boundaries. Positive PRL requires positive edge
overlap and permits the matching real edge inside the gap; a narrower extension
does not erase the wide object's spacing requirement. Zero or negative PRL
admits endpoint overlap at the gap boundary.
Euclidean separation includes exact equality and rejects different-net contact.
All distinct spacing values supply routing events. Same-net PORT, wire and via
metal are evaluated as one exact union before search and after each routed net,
so shape segmentation cannot shorten width or PRL or expose internal faces.
Final replay uses those complete metal objects. Maximal rectangles are derived by sparse
boundary rows and interval intersection, never by enumerating DBU sites. The
lower bounded decomposition is pre-admitted; geometry rows, perimeter intervals,
maximal rectangles and pair/edge checks consume the same invocation-local
noncopyable routing budget before expansion. Caller limits remain cumulative.
Scalar polygon behavior remains intact. Candidate and retained geometry use the
same checker; final pair work consumes the existing routing budget.

Spacing-object construction admits each phase from already known geometry counts.
It never reserves a fourth-power estimate from the entire raw polygon inventory.
The input and single-rectangle fast path admit input entries plus their fixed
output facts. The lower scanline compiler receives its existing pre-admitted
vertex/level probe bound. Subsequent phases reserve finite work before expansion:

| Phase | Known inputs | Admission bound |
|---|---|---|
| Boundary levels | B actual bands | 2B inserts plus sorting 2B entries |
| Union rows | R actual level gaps, B bands | R times band scan/append, interval sort/merge and row append |
| Boundary edges | Actual neighboring row interval counts | Side edges and both finite interval differences |
| Perimeter | E actual emitted edges | Sort E and at most two admissions per edge |
| Maximal rectangles | R rows, I total row intervals, M maximum row intervals | At most R(R+1)/2 row pairs, each with bounded interval intersection, coverage and output |
| Retained material | I actual row intervals | At most I material-band appends |

Every multiplication/addition remains checked. Actual loop/append charges use the
same exclusively owned cumulative budget; an earlier phase's unused reservation
does not reset consumed work or override the caller limit. Rectangle intersection
has at most I intervals because every endpoint belongs to an admitted row interval.
Coverage scans at most M intervals in each adjacent row. Empty row-pair iterations
and row starts are charged, so cancellation cannot be postponed by empty geometry.
Input, lower decomposition, intermediate storage and output are admitted before
their corresponding expansion. An unavailable bound, actual quota exhaustion or
cancellation remains a typed atomic failure. Same-net coalescing independently
admits its actual group count before per-group traversal; it cannot borrow an
assumed surplus from a spacing-object construction phase. This is a structural work contract,
not a claim that all finite inputs fit a caller's resources.

## State, Ownership, and Lifecycle

Projected geometry, candidate frontier, counters and output state belong to one
invocation. No shared mutable state or target-dependent isolation is introduced.
Event and visited-state storage is bounded by admitted geometry and the ceiling.

## Failure, Concurrency, and Constraints

Checked arithmetic precedes coordinate conversion and structural multiplication.
Cancellation is checked during access and search. Geometry operations have
vertex-dependent cost; this sprint makes no large-design throughput claim.

The internal spacing-object compiler forwards an optional supplemental cancellation
check to the bounded rectilinear decomposition. Task cancellation remains mandatory
and is ORed with this check; supplying a callback cannot disable it. The check is
invocation-local, synchronous and not retained. ProcessGeometry uses this existing
lower boundary to test cancellation after decomposition work deterministically;
ordinary routing callers keep the default false supplemental check.

## Verification and Change Impact

Native API and actual CLI tests verify wide/rotated PORT access, obstacle/OBS detours,
positive contact connectivity, exact source identity and raw retained geometry.
Rejections cover narrow/off-grid access, no path, fixed-contact semantics, caller
budget, overflow and cancellation with no successful artifact batch. Large track
counts retain bounded event work. DEF is parsed by the fixed standard reader;
connections, routing layers/points and fixed contacts reconstruct the same metal
and via regions as canonical JSON. Existing signal/ECO and source geometry tests
verify shared routing composition. Host width adoption is owned by Xcircuite.

The grammar authority is the Cadence-authored
[LEF/DEF 5.8 reference, NETS and Defining Routing Points](https://coriolis.lip6.fr/doc/lefdef/lefdefref/DEFSyntax.html),
mirrored by LIP6. Normal NETS width comes from LEF WIDTH; omitted endpoint extension
is half that width. Local fixed DEF values/reader/writer provide the behavioral oracle.

### Retained conductor/blockage admission

Native ECO repair delegates retained wire/contact blockage checks to this owner.
Each wire uses its retained positive even width and explicit ordered endpoint extensions. Each
named fixed contact uses exact translated source metal polygons on the applicable
layers; a via origin or bounding box is not a contact approximation. A positive-area Region
intersection rejects the candidate. The shared native profile projects placement
blockages only onto declared tracks selected by preferred/max routing layers. This
is a conservative native routing policy, not a DEF ROUTING blockage declaration.
Unrelated layers and cut polygons are excluded from this blockage policy; exact
source OBS and cut-spacing admission remain independently authoritative.
Edge-only adjacency is allowed by this scalar blockage profile; foundry spacing
qualification is not inferred. Missing wire width or fixed-contact source is a
typed unsupported input, never a caller-default substitution.

The finite check capacity is the checked product of blockage count and actual
wire/contact polygon count, including projection checks. The source router itself
clears preceding repair proofs when geometry changes, including direct CTS routing
composition; unchanged geometry preserves them. The existing positive caller
`maximumRoutingCandidateChecks` may lower that capacity. Cancellation is checked
before geometry projection and each intersection. No second connectivity graph,
site sampling, new resource cache, or geometry publication is introduced.

Exact single-RECT top ports use [TopPorts](../TopPorts/DESIGN.md). Their actual
transformed surface joins the existing terminal PORT map and net-owned occupancy.
The same full-width track-access/search/clearance/budget algorithm applies to
cell and top ports. Routing may update derived Pin access coordinates while the
immutable source rectangle, placement origin/orientation/status and use remain
unchanged. Missing geometry and obstructed access fail atomically.

## Exact Retained Route Contract

The canonical snapshot owns ordered original centerline points and width. A
`PhysicalDesignRouteEndpointExtensions` immutable value owns signed `beginDBU`
and `endDBU` distances along the outward tangents of those original points.
`RouteSegment.endpointExtensions` retains this value; `qualifiedFootprint()` is
the shared checked positive rectilinear rectangle projection. Lateral extent is
half the even positive width. Signed truncation is retained exactly. No consumer
rewrites centerline endpoints to encode a cap, pads a flush path, or infers missing
extension meaning from width. Native source routing explicitly creates half-width
extensions; geometry-smoke paths remain explicitly unqualified.
Each endpoint retraction is strictly shorter than the original segment length;
positive total area cannot admit a retracted endpoint beyond its original segment.

`Net.routingClass` uses `PhysicalDesignRouteClass.regular` or `.special` and
`Net.defUse` retains optional declared DEF USE. `Route.defStatus` retains typed
ROUTED/FIXED/COVER and `Route.defShape` retains optional special-route SHAPE.
Constructors choose regular/ROUTED explicitly; decoding absent qualification stays
absent and operations that need it reject. Optional USE absence remains absence,
including special nets and clock-family topology: port use and net isClock do not
infer source USE. Input attributes outside this finite profile are refused before
projection, including NEW/grouping, SHIELD/NOSHIELD, SOURCE/WEIGHT and properties.

| Invariant | Owner / consumer | Behavioral evidence |
|---|---|---|
| Ordered endpoints, width and signed caps remain exact | Snapshot / endpoint value | Reversed, vertical, flush, asymmetric and negative-cap footprint cases |
| One checked full footprint governs real metal | Router occupancy, ECO admission, characterized CTS projection | Retained flush path avoids false half-cap collision; malformed/missing geometry rejects |
| Container/use/status/shape survives output | Native DEF writer / public exporter | Four original special routes, width 200, unchanged points, flush caps and omitted USE |
| Missing or unsupported meaning cannot become success | Qualified projection / DEF export | Old absent extensions/class/status and negative DEF extension typed refusal |
| Immutable pages retain all new values | Host schema canonicalizer/codec | Exact bytes/page roundtrip and geometry-dependent facet identity |

The producer and exporter share this contract. Regular NETS must use the declared
default source WIDTH; SPECIALNETS retains its explicit width and supported scalar
source rules. DEF serialization preserves container class, declared USE, status,
special SHAPE, and explicit nonnegative ordered point extensions. Negative signed
geometry can be represented canonically but is typed unsupported for DEF output.
Finite native SPECIALNETS mutation preserves the original net container and optional
USE without deriving USE from net names or source PORT roles. It requires an explicit
`implementationConstraints.routeWidth`, checked against exact source scalar
MINWIDTH/MAXWIDTH/SPACING rules, and one common terminal access layer. It generates
unshielded ROUTED wires with no SHAPE and explicit half-width endpoint extensions;
original input endpoints and flush caps remain unchanged in the input revision.
Generated widths must equal the selected retained special widths before replacement.
FIXED/COVER, SHAPE-qualified, unqualified-width and special-via paths are refused
before deleting selected geometry. Routes on unselected nets remain exact obstacles.
Different terminal layers or a same-layer domain with no legal path do not fall back
to unsupported special-net contact serialization or a regular NETS container.
Caller-selected power net names do not exclude an explicitly special finite net.
Legacy
synthetic PowerStructure export and arbitrary source-bound routed DEF intake
remain incomplete and explicitly refused. This contract does not implement wider
special-net grouping or power-grid synthesis.

Values and footprint arithmetic are invocation-local Sendable state. Existing
route/search/input/output budgets and cancellation boundaries remain authoritative.
No database dependency, new shared state, or target-specific isolation is added.

[RouteEndpointGeometryTests](../../../Tests/PhysicalDesignEngineTests/RouteEndpointGeometryTests.swift)
owns the public width-only red, ordered signed footprint/overflow/retraction cases,
exact four-special-route producer/export pairing and atomic unsupported failures.
Existing ECO and source-routing tests exercise the actual shared projection.
[SpecialNetRepairTests](../../../Tests/PhysicalDesignEngineTests/SpecialNetRepairTests.swift)
owns actual four-special-net cell-change/reroute API behavior, exact class/USE/width,
source/PORT preservation, protected metadata and unavailable-path/limit/cancellation
refusals. Placement and ECO cell geometry changes pass the same special deletion gate.
Special topology splitting remains explicitly unsupported. Cell geometry changes invalidate routing rather than proving a repaired
electrical design; the module owns that candidate lifecycle contract.

## Minimum-Area Geometry Contract

`PhysicalDesignRoutingAreaRule` owns exact nonnegative micron-squared to DBU-squared
threshold projection using the existing exact-integer precision domain. It does
not convert area as a length. `PhysicalDesignRoutingAreaGeometry` consumes the
same immutable union facts as PRL, with an additional nonoverlapping material-band
table retained only on explicit AREA demand. Missing material facts fail and are
never interpreted as zero; existing PRL-only calls retain their preceding storage
and work admission behavior. Disjoint row intervals remove duplicate/overlapping metal before area is
summed. Area is checked UInt64, since the full Int32 coordinate domain can exceed
Int64 square area. Components join by overlap or a positive-length common edge;
corner-only contact remains separate. Holes contribute no metal.

Component membership, storage, pair traversal and union-find traversal consume
the invocation's same noncopyable work budget before allocation/work. The structural
ceiling derives from the admitted band count; a caller ceiling may lower it.
Cancellation and arithmetic/coordinate overflow remain explicit failures.
No new shared mutable state or target-specific synchronization is introduced.

This geometry contract alone does not remove the source AREA execution gate.
Routing composition must identify complete generated wire/via components and may
use exposed source PORT geometry as a known area lower bound. Abstract PORT/OBS
views do not contain complete cell-internal metal and cannot prove cell AREA DRC.
Bounded endpoint-extension repair, full spacing/grid/cut replay and exact final
candidate persistence remain required before AREA-capable routing is admitted.
[RoutingAreaTests](../../../Tests/PhysicalDesignEngineTests/RoutingAreaTests.swift)
owns numerical projection, independent coverage/component comparison, duplicate
and hole geometry, corner contact, UInt64 area, work ceilings and cancellation.

## Bounded AREA Routing Composition

Source routing groups known source PORT, retained/generated wire and fixed-via
metal by exact net/layer. AREA checks only components containing actual routed
wire or via metal; source-only abstract PORTs and OBS are not full cell layouts.
An exposed PORT contributes known physical area to a routed component, never an
invented cell-internal area. Different nets/layers and corner-only islands cannot
subsidize each other's threshold. Overlap is counted once.

Each insufficient selected component admits a finite search over its existing
wire segments, ordered route/segment and begin/end. A positive endpoint extension
adds at least the missing area beyond the component bounding box, snapped to the
manufacturing grid. It preserves original centerline endpoints, pin connectivity,
wire width, fixed-via identity and route status. A trial must fit the core, pass
source/caller spacing (including full PRL union replay), and strictly reduce the
number of routed area violations. The loop is bounded by the initial violation
count and consumes the same cumulative caller work budget. Unselected geometry
is never repaired; a deficient retained component fails explicitly.

No admissible extension is a candidate failure, not proof that no physical design
exists. Via-only islands without an extendable owned segment fail explicitly.
After repair, exact AREA/spacing/grid/cut/geometry replay precedes immutable
publication. The width/spacing capability gate permits AREA only for this owner;
other conductor constructors retain explicit unsupported behavior. Actual source
routing API/CLI tests must observe real extensions, exact reread and atomic refusal.

The admitted AREA profile currently owns ordinary source NETS routing and ECO
rerouting. Other conductor-producing stages, finite special-net deletion paths,
and technology-only conductor mutation remain explicit unsupported capabilities.
Floorplan/placement may consume AREA sources only while routes, vias, power metal
and fills are absent, checked on both input and output. Pure DEF serialization
preserves source-qualified widths and AREA-repaired endpoint extensions but
issues no area or production verdict of its own.

## Source Obstruction Width Policy

Source MACRO OBS admission explicitly tags an optional spacing-width override.
For the resolved ON/default policy, source minimum width controls only that
obstacle's width input to the PRL table. OFF uses actual maximal-rectangle width.
Neither mode changes geometry, real facing edges, projected parallel length,
intersection refusal or caller minimum spacing. Normal PINs, unconnected PINs,
fill, routing metal and hard request blockages retain their existing semantics.
The same tagged obstacle reaches path search, retained-metal replay and AREA
endpoint-repair replay. Scalar spacing is independent of width, so it is unchanged.
Other unsupported width-dependent rule families remain rejected by source intake.

[RoutingSpacingTests](../../../Tests/PhysicalDesignEngineTests/RoutingSpacingTests.swift)
checks width-only metadata, real overlap, preserved PRL, caller constraints and
wide actual candidates. Source routing API/CLI tests compare the same retained
wire beside a wide OBS under default/ON/OFF and beside an actual unconnected PIN;
positive JSON/DEF readback and same-source continuation preserve exact policy.

## Budgeted Fixed VIA Selection

`PhysicalDesignFixedViaSelection` owns exact candidate identity and deterministic
selection. A requested named master resolves only that exact fixed declaration; an
unknown name or mismatched layer pair fails and is never substituted. An unnamed
transition considers all DEFAULT fixed declarations for its canonical layer pair.
The selector orders stable source names and returns the first candidate whose
actual translated shape, construction bounds, centered route contact and caller
geometry checks all pass. Thus stable identity breaks ties only among legal
candidates; a large or blocked earlier name cannot hide a later legal candidate.

The SourceRouter supplies its existing exclusively owned cumulative work budget.
Catalogue ordering, candidate iteration and source shape/vertex materialization
are admitted before allocation/work; caller-specific metal/cut spacing and exact
obstacle/contact checks charge that same budget. Overflow, budget exhaustion and
cancellation propagate rather than being treated as an ineligible candidate.
Candidate cut admission compares only new cuts with one another and with the
already validated retained/source cuts; it does not repeat all retained pairs for
every DEFAULT alternative. Actual source shape translation and vertex-pair work
are charged before geometry work. Every primitive edge-pair iteration checks
cancellation. Positive-area intersection rejects overlapping distinct cuts, and
primitive boundary distance enforces positive scalar spacing even when separate
cuts touch. The shared ProcessGeometry `PhysicalDesignFixedCutSeparation` primitive
is also used by retained/source cut prevalidation, so a candidate can rely on that
same separation law. A polygon-union spacing operation cannot erase cut identity. No
candidate remains a finite-domain failure, not proof of global infeasibility.

```text
Typed fixed catalogue -> stable candidate identities -> existing run budget
 -> actual bounds/contact -> exact metal/cut/obstacle checks -> selected named VIA
 -> canonical JSON / standard DEF -> exact named-only validation on reread
```

Process-bound signal routing, reroute ECO, characterized CTS and finite special
power routing invoke the same SourceRouter. Their legacy source-free smoke paths
retain their separate unqualified contract. Redundant ECO preserves the existing
named master. No-budget `resolveVia` validates an explicitly selected named master
only; unnamed selection is typed unsupported at that boundary. DEF export does
not repeat automatic selection or choose a replacement.

All selected VIA names and source shapes survive JSON/DEF save and reread. The
selector adds no generator, geometry approximation, shared mutable state, cache or
new tool-qualification authority. Unused generation formulas remain nonexecuted.
[FixedViaSelectionTests](../../../Tests/PhysicalDesignEngineTests/FixedViaSelectionTests.swift)
owns multiple DEFAULT legal fallback/ties, source declaration permutations,
all-illegal atomic refusal, explicit unknown-master refusal, cumulative budget and
cancellation, and actual routing/ECO API/CLI persistence. Existing characterized
CTS tests verify composition through this shared router; full physical signoff
remains outside this compatibility contract.

## Source Routing Width Selection

The request-owned `sourceRoutingWidthPolicy` selects ordinary source routing width.
Absence and `uniform` preserve the existing positive even `routeWidth` contract.
`sourceDefault` asks ProcessGeometry to resolve each canonical routing layer's
exact declared LEF WIDTH and validate its MINWIDTH, MAXWIDTH and spacing rules.
The router does not duplicate source conversion or infer a missing source default.
The request/schema authority remains in the module's request contracts.

```text
Request width policy -> ProcessGeometry exact layer width/spacing
 -> layer-owned access cap / search wire / fixed-contact cap
 -> retained segment width and ordered half-width extensions
 -> qualified occupancy / AREA replay / JSON and source-aware DEF output
```

Each net retains one validated width per eligible layer. Boundary events include
all distinct half widths and their core insets. The shared event domain uses the
smallest inset so a narrower-layer access near the core edge is not removed by a
wider unrelated layer. Actual access caps and wire/contact footprints still pass
their own full-geometry core and source checks. AREA repair preserves each existing
segment's width. All derived search work consumes the same cumulative invocation
budget; this policy introduces no run-local budget reset or shared state.

A source-default request cannot select SPECIALNETS mutation, whose explicit width
contract remains separate. Unselected qualified SPECIALNETS coexist as exact
retained obstacles. Source-free operation cannot execute this source-derived
policy. Regular NETS output retains each layer's source default rather than adding
unsupported nondefault routing rules. The standard reader verifies DEF geometry;
source-bound native routed DEF intake remains explicitly unsupported.

[SourceRoutingWidthTests](../../../Tests/PhysicalDesignEngineTests/SourceRoutingWidthTests.swift)
owns unequal-source-width API/CLI routing, exact JSON and standard DEF reread,
source-bound ECO continuation, legacy uniform refusal, narrow-layer core-edge
access, selected SPECIALNETS refusal and exact unselected special retention, and
cumulative work/cancellation regressions.
[RoutingSpacingBudgetTests](../../../Tests/PhysicalDesignEngineTests/RoutingSpacingBudgetTests.swift)
verifies a real 27,126-entry segmented input, reference union geometry, exact caller
quota, one-below refusal and cancellation without a fourth-power reservation. Existing uniform routing,
fixed-contact and characterized CTS tests verify composition after this change.

## Fixed-Contact Terminal Access

Ordinary direct access retains a full-width cap contained in the terminal PORT
on its own declared routing track. When that direct access set is empty, a
terminal may instead seed an eligible neighboring track through an actual DEFAULT
fixed VIA. This finite profile addresses source PORTs that have no contained
track cap; it does not relax routing tracks for ordinary wire nodes.

The existing boundary-event domain additionally includes exact fixed-VIA source
vertex offsets. Candidate centers are finite event intersections, and the seeded
neighboring layer must satisfy its declared track. The VIA's actual metal on the
original terminal layer must be wholly contained in the actual source PORT union.
Its neighboring metal must positively contact that layer's full-width route cap.
All translated source metal/cut shapes and the neighboring cap must fit the core
and manufacturing grid. Existing exact source/caller spacing checks include OBS,
unconnected/PG PORTs, blockages and retained conductors; the shared fixed selector
checks stable eligible identity and the same cumulative cut-separation budget.
No origin, bounding-box or metadata-only contact substitutes for real metal.

```text
Unchanged source PORT -> exact contained terminal VIA metal
 -> emitted fixed VIA -> neighboring on-track full-width seed
 -> existing track-constrained search -> canonical contacts + wires
 -> JSON / source-aware DEF / actual conductor and electrode capture
```

Chosen start and target contacts are retained explicitly with exact master,
position and layer pair. Unchosen candidates never become output geometry.
Pin identity and source access layer remain unchanged; only the derived physical
contact coordinate may change. Existing final cut, complete metal spacing, AREA,
grid and source validation precedes publication. Failure, quota and cancellation
never publish a partial access contact. Candidate, containment and event work is
charged to the existing invocation-local budget.

[TerminalViaAccessTests](../../../Tests/PhysicalDesignEngineTests/TerminalViaAccessTests.swift)
uses the retained Sky130 INV Y PORT and fixed L1M1_PR shapes to verify the concrete
finite source-derived neighboring-track contact domain (containing the geometric
(805,7310) existence witness), actual chosen wire/contact JSON and standard DEF reread,
no legal contact, spacing refusal, exact quota/one-below and cancellation.
Actual characterized CTS subsequently verifies composition through PEX electrodes
and independently checked mapped-cell equivalence; these are not inferred from
this routing-only contract.

## Generated Path Normalization

`PhysicalDesignGeneratedRouteNormalizer` owns representation-only normalization
of newly generated source-backed wire paths before occupancy and canonical route
publication. It does not rewrite retained routes, source geometry, contacts,
ports, or AREA-repaired/custom endpoint extensions.

```text
Boundary-event path reconstruction -> explicit path ranges + protected contacts
 -> bounded same-direction collinear normalization -> exact wire footprints
 -> ordinary spacing/AREA/source replay -> canonical route -> capture and DEF
```

Only adjoining segments with the same layer, width, jumper flag, axis and forward
direction, and two declared half-width endpoint extensions, may merge. Both
forward and reverse reconstruction order are handled. The merged ordered outer
endpoints/caps retain the exact rectangle union and total centerline length.
A turn, gap, partial overlap, attribute change or custom cap is not merged.

Each explicit path range remains a separate merge boundary. After merging, exact
duplicate generated physical edges across the same net's path ranges are retained
once, using the first stable opaque ID. The key includes layer, width, jumper flag
and both endpoints; reversed endpoints are equivalent only with the same declared
half-width caps. Custom/AREA-repaired caps are excluded. This is not a general
overlap union, retained-route rewrite or numerical R/C law. The exact physical
union and sink/VIA anchors remain unchanged, while duplicate record length is
removed from the electrical inventory. Partial overlaps retain their existing
unsupported extraction boundary. CTS numerical capture and all later publication
gates consume the new inventory; old candidate/proof bytes are never retagged.
Terminal
coordinates and VIA coordinates on their actual layers are protected. Chosen
root/target node coordinates are retained under a bounded terminal-sized buffer;
protection does not rescan the full snapshot pin inventory. The raw
adjacent-event graph additionally protects every endpoint with more than two
unique neighbors; repeated copies of the same edge do not invent a new branch.
No merge crosses a protected shared junction. New segment IDs retain the first
opaque ID of each run, remaining unique and deterministic; they are not parsed
for topology. Route/net identity, pin identity/access layer, fixed-VIA identity,
all route/net attributes and exact process/source references remain unchanged.

The invocation's same noncopyable budget admits retained input, new output,
finite endpoint-neighbor storage and path/protection metadata before construction.
Checked counts bound validation, degree construction and the single normalization
pass plus a finite exact-edge set and in-place output compaction; each loop checks cancellation through the budget. Caller quota remains
cumulative. Failure returns no partial normalized output. No shared mutable state,
new public API, schema, facade or resource fallback is introduced.

[GeneratedRouteNormalizationTests](../../../Tests/PhysicalDesignEngineTests/GeneratedRouteNormalizationTests.swift)
compares exact source footprints with an independent Region union, ordered caps
and total length for nonduplicate paths, plus the actual CTS shared-trunk
duplicate witness's unique edge length and single DEF record, including reverse paths, branches/VIA/terminal boundaries,
layer/width/jumper changes, retained/custom geometry, exact cumulative quota,
one-below refusal and cancellation. Actual CTS capture subsequently measures
shape/contact/mesh counts and numerical behavior. Physical-union equality alone
does not prove unchanged PEX discretization, R/C accuracy or performance.

## Persistent Contact-History Search

The router owns one invocation-local contact arena. Each distinct source-bound
physical contact retains its Via value and the exact immutable/COW translated
shape buffer already produced by the fixed-VIA selector, once. Access records and
persistent histories hold dense contact indices; no expansion copies a whole
path or reprojects historical contacts. The arena keeps buffers alive until the
net completes or refuses. ProcessGeometry owns the borrowed exact cut-pair
predicate; the router passes both retained buffers and the shared budget.

Dense labels retain the coordinate node, selected root access identity, canonical
HistoryId, predecessor index and transition contact index. A binary min-heap of
label indices supplies the frontier, ordered by checked `g+h`, then `h`, then
stable label insertion index. `g` counts predecessor edges. `h` is the exact
reverse shortest edge distance to any current target access in the immutable
source-static event supergraph described below. Every actual history-legal edge
belongs to that graph, so this is a safe lower bound and each edge satisfies
`D[u] <= 1 + D[v]`. Heap ordering itself removes no state; the separate exact
dominance rule below controls redundancy. No optimal route or
completion within the finite allowance is guaranteed. Each heap comparison/move
is charged before work; queue entries never exceed the admitted S labels. Root access includes the exact selected master
and source context. Distinct DEFAULT contacts at the same node remain distinct
accesses. At one node, exact contact-set inclusion and predecessor edge count
establish dominance: an existing label with `g <= candidate.g` and a subset of
candidate contacts rejects that candidate before arena growth only when the
existing label also has every target-acceptance capability of the candidate.
The actual target gate requires a nonnil predecessor: a seed with `previous=nil`
cannot dominate or retire a progressed label with `previous!=nil`. Both dominance
directions use this same capability order directly, without inferring it from
a caller-provided distance. Equal histories
from different valid accesses of the same root terminal share this rule; the
winning label retains its own exact root access and predecessor path. Different
master/contact sets remain separate when neither dominates the other.

Node buckets are linked dense label indices, without copied path/contact arrays.
A newly admitted subset with no greater edge count retires dominated labels but never removes
their immutable predecessor records. Retired heap entries are skipped; descendants
may still reconstruct through a retired, physically valid prefix. Aggregate
accepted labels, including retired records, remain capped by S. Membership,
bucket scans, retirement and all storage growth charge the same caller budget.

At the hard label limit only, a cold-path resource diagnostic scans each existing
node-bucket/label entry and frontier entry once. It emits only fixed scalar counts
(accepted/active/retired labels, frontier status, node/bucket maxima and active-open
g/h ranges), with the complete failure message capped at 512 UTF-8 bytes. A -1
range means no active frontier entry. No path, shape, source text or per-event
trace is retained. Checked scan work is admitted and charged to the same budget
before scanning, with cancellation checks before and after. Insufficient caller
allowance or representable budget capacity preserves the original resource
failure and explicitly marks the observation unavailable. Other failures,
including cancellation, propagate unchanged; no catch-all fallback is used. Successful search and
its order, source laws, arena limits and caller ceiling are unchanged.

Histories share immutable parent prefixes. Physical contact reuse adds no entry.
Count/fingerprint buckets locate candidate contact sets, but exact membership
comparison establishes equality; a hash is never the authority. Equivalent sets
reached in different orders reuse a HistoryId, so loops do not inflate identical
histories. Different contact sets retain distinct history identities; only the
explicit node-local dominance rule removes redundant labels.

Every transition must fit retained/source cuts, already committed contacts from
this same net, and the selected label's tentative contact history. Same-net,
same-master, same-position and same-layer-pair contacts may reuse one physical
contact. Distinct physical cuts still obey the complete source overlap and
edge-to-edge SPACING law, including same-net contacts. A target is accepted only
after its specific terminal-access contact passes the same checks; reconstruction
uses the saved access identity rather than the first access sharing its node.
The final full cut replay remains mandatory before publishing any net geometry.

Dominance preserves the current search's cut/connectivity continuation contract:
every winner is a continuous path from a source-validated root access, and a
subset of already legal contacts cannot strengthen a future contact or target's
cut constraints. Committed same-net contacts are a common subset of every label.
Temporary same-net wire metal is not an obstacle in this search. Dominance does
not assert equality of prefix metal, minimum-AREA repair outcomes, shortest
routes, resource use or completeness over all final-qualified layouts. The
existing state abstraction already excludes prefix-metal identity. Chosen
geometry still passes complete cut, metal-spacing, grid, connectivity and source
AREA/AREA-repair gates before publication; any failure remains a typed refusal.

[RoutingContactHistoryTests](../../../Tests/PhysicalDesignEngineTests/RoutingContactHistoryTests.swift)
checks canonical histories, dense label identity, finite admission and cancellation.
[RoutingContactSearchTests](../../../Tests/PhysicalDesignEngineTests/RoutingContactSearchTests.swift)
checks actual source-router history and terminal-access composition, stable
goal-directed heap ordering and its cumulative work admission.
Focused regressions retain the 170-DBU cut / 190-DBU spacing counterexample where
340-DBU center pitch is illegal, and prove that an alternative legal history or
terminal access remains searchable. Original Sky130 values, tracks, placements
and source PORTs remain fixed for actual API/CLI integration. Quota, cancellation,
multiple-master access identity and failed-publication behavior remain explicit.

## Net-Owned Static Event Supergraph

The router builds one graph for the exact current net, source geometry, core,
resolved layer widths/clearances, declared tracks, relevant occupancy, retained
other-net contacts, source cuts and bypass-layer policy. This immutable context
lasts through every terminal connection of that net and is never reused for
another net, invocation or changed context. No pose-only geometry verdict cache
or shared state is introduced.

Every wire edge uses the existing full-footprint core/track/bypass/clearance
predicate. Every named DEFAULT contact edge uses the existing fixed selector,
metal-cap contact/clearance, cut obstacle and intrinsic/source/retained cut
predicate. Each eligible source master at each coordinate remains a distinct
parallel edge retaining its exact contact-arena identity. Only tentative and
committed same-net history cuts are omitted from graph qualification; actual
search still checks them against every selected contact and terminal access.
Static geometry is qualified once per edge in this frozen context rather than
recomputed for every history label. Failures and unsupported source semantics
propagate through the same predicate contracts.

```text
Frozen net/context -> exact static wire + named contact edges
    -> target reverse BFS distances D -> g+D history-label frontier
    -> actual history/terminal cut admission -> selected source-root path
    -> complete cut/metal/grid/AREA replay -> immutable publication
```

For `N=L*X*Y` dense event nodes and `V` eligible DEFAULT masters, the checked
directed edge allowance is `2*N + 2*X*Y*V + 4*A`, where A is the admitted terminal
access record count (zero for graph callers without terminal jogs): each positive-axis wire pair is
considered once and each master/coordinate contact once, then stored in both
directions. Dense head/tail arrays and a flat linked edge arena preserve stable
insertion order without path copies. Named-master ties retain source-name order.
Node, edge, head/tail, distance and queue storage, edge qualification, BFS probes
and cancellation all use the existing cumulative budget before growth/work.
Reverse BFS distances and its queue each have N entries; each node is enqueued
at most once and each directed edge is scanned once. The existing S label and
contact/history arena limits and caller ceiling are unchanged.

Reverse BFS starts from all static target-access nodes. Its graph is a supergraph
of every history-legal continuation in the admitted event domain. Therefore an
unreachable node may be skipped, while a finite D is a lower bound even when a
target contact is forbidden by a particular history. A zero D does not grant
seed target acceptance; the existing predecessor capability gate still applies.
No label is removed merely for a large distance or an arbitrary preferred path.
Connectivity, exact target contact identity, full final source checks and the
limits on layout completeness remain owned by the existing search/publication
contracts above.

## Actual Saved CTS Candidate Detailed-Routing Integration

`ActualSky130DetailedRoutingTests` in PhysicalLogicHandoffTests resumes the retained
primary/derived Native CTS CLI candidates through their exact JSON layout references.
It runs no replacement CTS. Before routing, the public RoutingSourceAdoption owner
checks an explicit old-to-new source transition against the saved parent. The new
manifest replaces only the technology asset with the complete original 18,167-byte
nominal Sky130 technology LEF and adds its previously absent layer identities.
Native IDs 1 through 5, selected cell/Liberty bytes, logical inputs, cell poses,
CTS topology and existing conductors/contacts remain bound to the original parent.
The fixture neither strips manufacturing laws nor clears metadata to bypass intake.

```text
retained actual CTS JSON + old selected-source request + full-source request
  -> public checked source adoption -> fresh input revision + typed lineage
  -> detailed-routing API / CLI -> saved candidate + standard DEF
  -> source geometry / terminal connectivity / shared DEF readback
  -> independently checked functional export + saved certificate reload
  -> exact candidate DEF / physical-name source netlist for routed PEX
```

The source adopter owns compatibility, metadata transition, invalidation and tracks
for the newly selected routing layers. Existing li1/met1 tracks remain unchanged;
new tracks derive from the source pitch/offset and retained core through that owner.
The fixture declares the additional layer map and six allowed routing IDs, uses
all original fixed VIA declarations, and persists the checked adopted snapshot as
a new immutable JSON input. Fresh API and CLI filesystem roots consume identical
adopted input bytes, full source bindings and lineage. A preparation test saves the
four primary/derived API/CLI source subjects. The independent integration driver
uses each new manifest to obtain a fresh checked Logic baseline through Runtime;
the routing test requires that saved binding and publicly reloads it. The old
baseline remains parent evidence. Each primary/derived API/CLI subject has its own
explicitly named execution test and 240-second outer runner. The caller-owned CLI
profile uses a 180-second child deadline. An isolated bounded observation completed
the actual derived CLI naturally in 114.411 seconds with a 3.19 GiB peak, producing
all four artifacts and snapshot bytes identical to the completed API candidate.
That measurement supersedes the inadequate 60/100-second child profiles; the prior
combined-family 120-second run also expired. The remaining 60-second outer allowance
is reserved for cleanup and validation. Kernel work limits and routing rules are
unchanged; this caller profile is not a runtime completion guarantee.
Every launched CLI child is reaped on exit and killed before reaping if still alive.
Four separately named
saved-result tests decode an already completed result without invoking routing or
rewriting that result. Both modes call the same complete geometry, connectivity,
DEF, source-baseline and checked-proof validation body. Empty or partial result
bytes fail; their mere path existence never establishes completion. Repeated proof
publication uses the existing immutable store's exact-byte retry contract, and an
existing handoff must match its regenerated bytes. No subject is conditionally
skipped. Existing `.geometrySmoke`
intent with required source geometry does not grant a source-free fallback.

Ordinary routing preserves CTS-owned route/contact families and logical topology.
Source adoption invalidates preceding timing and repair observations; routing cannot
reuse pre-route STA or extraction as postroute evidence. The test checks immutable
output bindings, actual connectivity, retained layer/default-width DEF geometry,
and independently checked RUP persistence/reload against the new checked baseline,
original bit design and exact Liberty/explicit four-PG functional assumptions. The
driver verifies unchanged original bit bytes, seed, source, Liberty and PG/PVT
assumptions while obtaining that new baseline. The changed process manifest is a
new input identity, never substituted into the older functional receipt. The test
requires the fresh baseline's exact manifest/library binding before checking the
routed candidate. Same-candidate timing joins remain independently checked downstream.

The independent rectangular connectivity reference keeps every retained material
and PORT record in its graph. Same-layer positive-area overlap or a positive-length
shared edge joins exact metal, including abutting source RECT fractures. A corner
point, a one-DBU gap, another layer or the same logical pin name alone creates no
connection. The original dfxtp Q PORT has seven edge-abutting RECTs; requiring only
positive area between each pair falsely split that continuous source union. Boundary
regressions retain these distinctions, and removing the actual primary net-0 met2
bridge must leave its output terminal unreachable. Named source-qualified VIA
contacts retain their explicit inter-layer connection rule.

The old selection report remains historical provenance of the unchanged selected
cell and Liberty views and the preceding technology view; it is not the authority
for the newly adopted full technology bytes. Complete raw-source retention and this
routing integration do not establish full foundry legality, routed PEX/STA closure,
supply qualification or production release. The next extractor consumes the newly
exported candidate netlist and exact saved DEF. Exact terminal/source contracts are
owned by [PhysicalDesignLogicHandoff](../../PhysicalDesignLogicHandoff/DESIGN.md)
and the PEX/DEF owners; this test adds no parasitic numbers or synthetic pin points.

## Pin-Access Failure Attribution

A bounded test-only observation of the actual full-net failure retained unpublished
prior routes/contacts and identified the counterexample below. The temporary
internal partial-snapshot error payload and its one-shot test were removed after
attribution; failures again retain only their original code/message. The diagnostic
JSON is evidence of the failing call, never a completed layout artifact. The
separate only-net-3 observation preserves the unchanged source predicate control.

The subsequent bounded path-failure observation found all 23 net-2 root accesses
statically unreachable (`reverseDistance = -1`, zero search labels), with earlier
net-0/net-1 actual routes present. Contact-history/dominance changes are therefore
outside this cause. Its temporary payload/test were removed after attribution.

## Source Terminal Access Reservations

Before ordinary net search, the same source access enumeration runs once for every
selected net in stable-ID order against retained geometry and earlier other-net reservations. Each
terminal reserves the first admitted access in the existing deterministic order:
the full-width cap, plus every exact translated metal shape of its fixed contact
when required. Contact cut compatibility uses the existing borrowed
`routingCutPairFits` source law and retained shape buffers. No new source rule,
track, PORT, cell pose or contact approximation is introduced.

The prepass also retains one source-derived Boolean per net: whether any terminal
requires a fixed contact because its full-width direct-track access set is empty.
The routing phase processes these constrained nets first, then other nets, with
stable net-ID order within each class. Classification reuses the admitted access
sets; it never infers capability from D/Q names, instance/opcode or source spelling.
It grants no new access, retries no failed route and changes no source predicate.
The finite classification records and sort consume the same cumulative budget and
cancellation checks. The earlier actual net-0 y=4930 conductor closed a net-2 escape
candidate before its search; terminal cap reservation alone does not protect the
complete escape channel. This order is a deterministic search policy, not a joint
routability guarantee. Actual complete connection/DEF/proof readback remains the
integration completion condition.

```text
source PORT + retained conductors -> shared access predicate -> net-owned reservation
    -> every net's search excludes other-net reservations -> actual final replay
```

Reservations carry their net identity, never block their own net, and are separate
from actual occupancy and output routes/vias. Search may choose any admitted access
for its own net; its unused reservation remains conservative protection until the
call ends. Source clock families remain retained obstacles. A conflicting or
unavailable reservation fails through the existing typed access refusal; there is
no unreserved fallback. The policy preserves one access, not a proof that every
otherwise routable multi-net problem is solved. Final connectivity, grid, metal,
cut and AREA replay still checks only actual generated/retained geometry.

Before access enumeration and search, the combined retained/source occupancy and
other-net reservation list passes through the existing `coalesceMetal` owner.
Its same-net/same-layer union is required for actual PRL width and boundary facts:
adjacent 100-DBU landing RECTs can form a 200-DBU-wide conductor whose source table
requires greater clearance. Neither per-polygon checks nor coalescing reservations
separately from source/retained metal establishes this invariant. The shared union
builder charges its actual work/storage and cancellation through the same budget.

Both phases share the same cumulative caller allowance and cancellation checks.
The reservation count is bounded by the checked sum of selected terminal counts.
Each retained cap/contact/shape record and vertex work is charged before growth;
translated contact arrays are COW-retained from the existing contact arena, not
reprojected for pair probes. Per-net access/history arenas are released after each
phase iteration; reservations live only through the routing call. The second
enumeration and larger exact obstacle inventory are real additional work, not a
free cache or an enlarged caller ceiling.

The actual counterexample is `net-2`'s 140-DBU met1 conductor at y=3570 crossing
`cell-1/D`'s only initially admitted escape row. Its x range 1495...17780 and y
range 3500...3640 intersect the actual L1M1_PR landing at (9845,3570), whose met1
extent is x9700...9990/y3455...3685. The unchanged net-3-only run admits that contact;
the unchanged full run fails after publishing net-2 only to call-local state.
`RoutingAccessReservationTests` owns focused conflicting-net, quota and cancel
counterexamples, including a split-landing actual-router regression where a
150-DBU gap admits each 100-DBU RECT but violates the union's 200-DBU requirement.
`ActualSky130DetailedRoutingTests` owns actual full API/CLI and
saved-source readback, including retained clock geometry; this policy does not
replace that required integration evidence.

## Terminal-Adjacent Track Jogs

LEF DIRECTION selects the preferred generation axis; it is not a physical
prohibition of orthogonal metal. Besides preferred-axis event edges, each distinct
source-admitted terminal access node may connect to the immediately adjacent
parallel declared track on either side. Neighbors are considered in increasing
then decreasing coordinate order; duplicate access nodes contribute once. A
checked ordinal difference of exactly one source pitch is required. If that
adjacent track has no existing event coordinate, no edge is added; a sparse
event list never authorizes skipping an intermediate declared track. No
other node receives a new offpreferred edge. Bypassed jumper layers retain their
existing restriction and receive no such edges. Every jog uses the same exact
source width, endpoint caps, manufacturing grid, core, PORT/OBS and foreign-owner
spacing predicates. Via/cut/history and final union/AREA validation are unchanged.

The node set remains the existing bounded event grid. The static graph admits
at most four directed jog edges per admitted access record, with checked storage
arithmetic and the same caller budget before growth. Deduplication, neighbor scans
and geometry work are charged to that budget; there is no new retry or net order.
Retained axis-aligned physical wires need not match the preferred direction, but
still require exact qualified widths, both endpoints on declared tracks, grid,
core, spacing and AREA admission. This distinction permits a saved generated jog
to resume without reinterpreting DIRECTION as a ban.

The actual derived counterexample has 165 source root accesses with reverse
distance -1 and zero search labels/history rejections. Net3's cut at
(17710,4590) leaves only 170 DBU to the required y4930 cut, below mcon's 190 DBU.
The upper y5270 escape conflicts with the unchanged net0 PORT. A terminal-only
li1 jog toward the neighboring track x18170 preserves these source rules instead
of changing them. RoutingTerminalJogTests owns shared-predicate legality, blocked
preferred escapes, actual routed jog, budget/cancellation and save/reload/reroute
regressions. Actual full-source API/CLI evidence remains independently required.

The router's internal `terminalTrackJogs` option defaults to true for ordinary
routing. The [CTS owner](../ClockTreeSynthesis/DESIGN.md#cts-candidate-generation-profile)
selects false for its fixed-exposed-electrode candidate profile. False admits no
jog edges or extra terminal-edge storage; it preserves all physical validation,
source laws and the retained orthogonal-metal admission contract.
