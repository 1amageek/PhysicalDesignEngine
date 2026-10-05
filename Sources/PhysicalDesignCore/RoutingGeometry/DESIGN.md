# Routing Geometry

## Purpose and Scope

Own bounded source-bound native signal routing, finite special-net routing and selected-net ECO rerouting.
Parent: [PhysicalDesignCore](../DESIGN.md). No children. Existing stage wrappers
compose this responsibility directly; CTS and production qualification are separate. Source routing rejects existing CTS topology records and synthetic power-grid structures. Finite special-net point-to-point routing does not synthesize a power grid.

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
    -> boundary events -> bounded lazy rectilinear search
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
  advanced rule semantics fail. Effective scalar conductor clearance is the greater
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
- Transitions use exactly one admitted DEFAULT fixed via for the pair. All metal
  and cut footprints fit construction bounds and avoid excluded geometry. Actual
  source cut overlap/edge spacing is checked for expanded PORT cuts and all
  contacts, including same-net contacts. Cut OBS and excluded PORT footprints
  also reject translated contacts. Repair center-distance estimates cannot substitute for cut geometry.
- Connections are deterministic in stable net/pin order. A lazy search uses finite
  coordinate events from core/PORT/obstacle boundaries, conductor/via extents and
  adjacent declared track locations. It never enumerates every track/site.
  Exhaustion means no path in this retained event domain, not global optimality.
- The structural candidate ceiling is checked from actual event counts, layers,
  terminal connections and maximum state degree. For each net, with P terminals,
  L eligible layers, X x-events and Y y-events, the checked bound is
  `P*X*Y + (P-1)*L*X*Y*(L+3)`. Stage structural capacity is the checked sum
  of these net bounds, derived before each net against prior retained allocation.
  The caller may supply a positive
  `maximumRoutingCandidateChecks`; effective ceiling is the smaller value.
  Candidate checks include access, conductor and contact admission. No guessed
  numeric default, unbounded frontier allocation or implicit fallback is used.
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
-> connect terminal PORTs -> retain actual geometry -> final source/contact checks
-> complete immutable artifact batch -> completed result. Publication failures do
not claim completion. Geometry completion keeps timing notApplicable and production
blocked; characterized timing and production routing requests remain unsupported.

## State, Ownership, and Lifecycle

Projected geometry, candidate frontier, counters and output state belong to one
invocation. No shared mutable state or target-dependent isolation is introduced.
Event and visited-state storage is bounded by admitted geometry and the ceiling.

## Failure, Concurrency, and Constraints

Checked arithmetic precedes coordinate conversion and structural multiplication.
Cancellation is checked during access and search. Geometry operations have
vertex-dependent cost; this sprint makes no large-design throughput claim.

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
