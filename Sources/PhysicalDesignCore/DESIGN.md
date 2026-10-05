# PhysicalDesignCore

## Purpose and Scope

PhysicalDesignCore is the package's state, executor, mutation and persistence module.
Parent: [package design](../../DESIGN.md). Child:
[TechnologyConstraints](TechnologyConstraints/DESIGN.md),
[ProcessInputs](ProcessInputs/DESIGN.md),
[MasterGeometry](MasterGeometry/DESIGN.md),
[LegalPlacement](LegalPlacement/DESIGN.md),
[ClockTreeSynthesis](ClockTreeSynthesis/DESIGN.md),
[RoutingGeometry](RoutingGeometry/DESIGN.md), and
[ProcessGeometry](ProcessGeometry/DESIGN.md), and
[StandardLayoutExport](StandardLayoutExport/DESIGN.md), and
[TopPorts](TopPorts/DESIGN.md).

## Responsibilities and Boundaries

The module owns native request execution and canonical snapshots. PDKKit owns
process manifest semantics; swift-mask-data owns standard parsing. Host approval,
release and database persistence remain outside this module.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Execution and artifact invariants | Public stage behavior | Production remains blocked |
| [TechnologyConstraints](TechnologyConstraints/DESIGN.md) | child | Verified snapshot preparation | PDK/LEF to native tracks | No process qualification claim |
| [RoutingGeometry](RoutingGeometry/DESIGN.md) | child | Source-bound access, search and conductor/contact geometry | Bounded native routing | Canonical widths and exact source geometry are required |
| [LegalPlacement](LegalPlacement/DESIGN.md) | child | Bounded legal-row allocation | Exact occupied intervals and source poses | Geometry allocation does not establish timing-driven closure |
| [ClockTreeSynthesis](ClockTreeSynthesis/DESIGN.md) | child | Explicit source-bound CTS and passive RC model observations | Bounded lower-contract composition | Model convergence cannot grant physical signoff |
| [ProcessGeometry](ProcessGeometry/DESIGN.md) | child | Exact mapped cell/pin/site/via shapes | Native process projection | Projection alone does not prove native closure |
| [MasterGeometry](MasterGeometry/DESIGN.md) | child | Required exact LEF master dimensions | Canonical cell construction | No fabricated dimensions |
| [ProcessInputs](ProcessInputs/DESIGN.md) | child | Explicit asset-ID-bound standard views | Shared exact physical source intake | Input identity and manifest role are validated before projection |
| [StandardLayoutExport](StandardLayoutExport/DESIGN.md) | child | Bounded source-bound DEF pairing | Public native serializer access | Same snapshot/request; no stage rerun |
| [PDKKit](../../../PDKKit/DESIGN.md) | depends on | PDKCore manifest values | Process identity and layer mappings | Use the fixed package implementation |
| [swift-mask-data](../../../swift-mask-data/DESIGN.md) | depends on | LEF reader and typed axis values | Standard view parsing | Common codec owns loss admission; native profiles own rule support |

## Architecture

```text
NativePhysicalDesignExecutor -> ProcessInputs -> TechnologyConstraints -> mutation -> artifacts
    -> MasterGeometry during source-bound DEF decode
ProcessInputs -> ProcessGeometry -> canonical input admission -> mutation -> output admission
    -> JSON resume reference + bounded DEF interchange + diff/manifest
```

## Contracts and Invariants

Canonical snapshot schema 2 retains standard cell orientation, source-bound process
references, pin layer, row site and fixed-via master. ProcessGeometry admits exact
source geometry before and after mutation. Public bare mutation cannot bypass intake.
The native result's physical reference is JSON for lossless same-source resume; DEF
remains the separate bounded standard interchange artifact.

The package design owns stage/result and artifact contracts. With explicit tracks,
every generated signal/ECO/clock segment must lie on at least one declared track
of the same layer and direction: coordinate minus origin is nonnegative, divisible
by spacing and less than count in track units. Checked subtraction rejects overflow.
Canonical cells require explicit dimensions. The DEF standard-format adapter
resolves admitted LEF masters or requires complete explicit smoke dimensions;
missing or contradictory geometry fails before snapshot publication.
With exact process inputs, the DEF adapter constructs the invocation projection
when explicit UNITS is admitted and returns it to the executor for reuse. ROW uses
the exact oriented SITE dimensions; STEP defines repetition and does not define
site height. The current profile admits one horizontal row repetition (BY 1) and
checks exact contiguous site pitch. Components retain standard orientation and
oriented master SIZE. Connected component pins retain actual source direction,
layer and a deterministic declared boundary point after ORIGIN/orientation/placement;
this reference point is not a proof of width-aware track access or route closure.
Unknown attributes/sections and incomplete headers fail in the process-bound profile;
existing track layers resolve explicitly and CLOCK use comes from the declaration.
Input byte identity is verified before decoding. Combined row/rectangle bounds use
checked arithmetic, so malformed input cannot trap before geometry admission.
Exact single-RECT top ports use [TopPorts](TopPorts/DESIGN.md); routed import remains explicitly unsupported.
Bounded normal-net routing output is owned by RoutingGeometry. Source layers
resolve through the projection; names are never converted by stripping an M prefix.
The no-track geometry-smoke convention remains an explicitly incomplete path.
Source-free off-grid point access remains unsupported. Source-bound routing selects
actual width-aware locations inside exact PORT areas through RoutingGeometry.

ECO resizing is an explicit master replacement: `ecoReplacementMaster` must name a
selected exact process master. Without process sources or a selected master the
operation fails; no dimension delta or generated master name is supported. Both
masters must expose the same complete physical pin-name/direction/use interface.
The candidate retains instance identity, pose and connectivity, adopts oriented
source SIZE and reconstructs its connected pins from declared replacement PORTs.
Row/site/symmetry, core and collision admission still apply before publication.
The operation provides physical geometry evidence only; logical equivalence and
characterized timing improvement remain separate required closure work.

Native power, signal/ECO routing, CTS and redundant repair share fixed-via source
resolution. A newly constructed layer transition requires exactly one selected
DEFAULT fixed via for that declared routing-layer pair; an explicitly retained
master keeps its identity. Missing/ambiguous defaults fail, without a name or
layer-number fallback. This center-joined profile requires both routing footprints
to contain the via origin and every translated shape to fit the construction core.
Redundant candidates retain the original master and test full footprints before
location acceptance. Multi-transition route search, full routing DRC and
pin-access closure remain B5. ProcessGeometry owns basic fixed-contact width,
spacing and enclosure admission plus source routing-layer identity; fixed source
resolution alone does not qualify native routing.
The same path constructor materializes transitions at declared pin access layers
and each segment-layer boundary. A bend via alone cannot bridge a different pin
layer at an endpoint. Repeated same-net transitions at the same position/pair are
retained once; no process-free pin layer is inferred.

CTS characterization and source-bound passive RC model execution are owned by [ClockTreeSynthesis](ClockTreeSynthesis/DESIGN.md). That component
composes existing placement, routing, exact process, Liberty, PEX and passive
transient contracts; it does not introduce a separate physical graph owner.

CTS and ECO inserted buffers require a selected exact source master with one
declared input and one output signal/clock port. Port names are not assumed to be
A/Y. Instance dimensions, orientation and placement come from its source SIZE and
compatible SITE row. The bounded placement and source router owners provide core/cell/blockage and
width-aware PORT/OBS admission.
`ecoBufferMaster` selects the ECO source. Source-bound CTS selects its buffer master
through the explicit model contract owned by ClockTreeSynthesis.
Source-free buffer insertion fails. ECO insertion publishes the exact split-net
geometry candidate with invalidated route/clock evidence and an explicit routing
follow-up; it does not implicitly run a second mutating routing stage. Source-bound CTS preserves original cell poses and unrelated routes, then creates
fresh unpublished clock families before measured model constraints admit a tree. Functional equivalence and timing
closure remain separate. Antenna protection insertion stays explicitly unsupported
until B7 can derive and recheck antenna metrics; no fabricated diode or ratio
improvement is a successful protection result.

[LegalPlacement](LegalPlacement/DESIGN.md) owns native placement candidate search,
caller/structural ceilings and pin pose changes. The module composes that contract
with exact source admission and immutable output publication.

## State, Ownership, and Lifecycle

Placement and ECO preserve cell-owned pin offsets through checked translation.
LegalPlacement reconstructs exact source ports when it selects a different orientation.
Coordinates remain instance-global and source-relative offsets survive relocation.
After a cell pose/master/dimension change, retained routes/vias, clock trees and
global placement/routing/repair evidence no longer prove the new snapshot and are
invalidated before fresh stage evidence is produced. Re-running an unchanged pose
preserves existing evidence. Routing and CTS must be rerun for changed geometry;
geometry-smoke stage completion does not claim timing or routing closure.

Technology and mutation values are invocation-local, Sendable values. The store
owns input byte verification. No shared mutable state or conditional isolation is added.

## Failure, Concurrency, and Constraints

Failed preparation or grid validation produces diagnostics and no successful revision.
[RoutingGeometry](RoutingGeometry/DESIGN.md) owns source-bound search, cancellation,
conductor widths, contact admission and bounded normal-net output. Source-free smoke
retains an explicitly incomplete single-bend algorithm.

## Verification and Change Impact

[NativeExecutionTests](../../Tests/PhysicalDesignEngineTests/NativeExecutionTests.swift)
and the component tests exercise retained bytes and stage failures. Grid changes
affect signal routing, ECO rerouting and CTS. Technology changes affect all stages
that receive technology LEF. Verify these paths before package/CLI integration.

Output artifact writes require an explicit producer-owned logical ID. Native stage IDs
name the stage and output role; immutable content identity remains in the reference,
and storage paths remain in availability. The store preserves the requested ID
rather than deriving it from a path. This separates semantic output names from
locations and keeps host identifier validation independent of local filenames.

### ECO blockage admission and dependent evidence

Native `timingECO`/`drcRepair` construction admits retained wire/contact geometry
against the native routing profile's applicable candidate blockages before recording
a geometry repair proof. The
[RoutingGeometry](RoutingGeometry/DESIGN.md) owner uses actual square-cap
per-segment conductors and exact transformed fixed-via metal regions. The standard
DEF representation remains a placement blockage. Native source routing conservatively
excludes that rectangle on its selected eligible metal layers; mutation reuses this
same policy without adding cut exclusion or spacing. A wire or contact intersection, unknown width/source, arithmetic error, exhausted caller
check ceiling, or cancellation rejects the invocation-local candidate; retained
routes are neither deleted nor silently rerouted. New blockage rectangles require
checked coordinates and core containment.

A successful changed blockage preserves route/via bytes and clock-tree topology,
but clears preceding routing, placement and repair proofs and clock timing/path
measurements. A changed route/contact clears preceding repair and clock timing/path
measurements while retaining the source router's newly established routing evidence.
An unchanged routing geometry retains its preceding measurements. These geometry
admissions do not consume PEX, STA, DRC, LVS or qualification feedback; the host
candidate feedback decision is a separate owner and must bind fresh exact inputs.

Behavioral owner: [ECOGeometryAdmissionTests](../../Tests/PhysicalDesignEngineTests/ECOGeometryAdmissionTests.swift). The same source-bound design tests
crossing wires, endpoint caps, fixed-contact footprints, disjoint retained geometry,
unknown geometry, bounded failure/cancellation, immutable API artifacts and route
change versus no-change invalidation. Existing routing tests own source search and
standard export; characterized CTS and host feedback are not repeated here.
