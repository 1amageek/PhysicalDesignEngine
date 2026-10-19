# PhysicalDesignCore

## Purpose and Scope

PhysicalDesignCore is the package's state, executor, mutation and persistence module.
Parent: [package design](../../DESIGN.md). Child:
[DEFImport](DEFImport/DESIGN.md),
[TechnologyConstraints](TechnologyConstraints/DESIGN.md),
[ProcessInputs](ProcessInputs/DESIGN.md),
[MasterGeometry](MasterGeometry/DESIGN.md),
[LegalPlacement](LegalPlacement/DESIGN.md),
[ClockTreeSynthesis](ClockTreeSynthesis/DESIGN.md),
[RoutingGeometry](RoutingGeometry/DESIGN.md), and
[RoutingSourceAdoption](RoutingSourceAdoption/DESIGN.md), and
[ProcessGeometry](ProcessGeometry/DESIGN.md), and
[StandardLayoutExport](StandardLayoutExport/DESIGN.md), and
[TopPorts](TopPorts/DESIGN.md), and
[RepairMeasurement](RepairMeasurement/DESIGN.md).

## Responsibilities and Boundaries

The module owns native request execution and canonical snapshots. PDKKit owns
process manifest semantics; swift-mask-data owns the standard LEF/rule input codecs.
[DEFImport](DEFImport/DESIGN.md) owns the bounded native DEF input adapter. Host approval,
release and database persistence remain outside this module.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [DEFImport](DEFImport/DESIGN.md) | child | Bounded public DEF parser | Native standard input and exact dimensional declarations | Declaration grammar cannot create or replace cell geometry |
| [RepairMeasurement](RepairMeasurement/DESIGN.md) | child | Exact source/rule-based repair verdict | NativeDRC and actual conductor capture | Legacy scalar ratios are unverified |
| [Package](../../DESIGN.md) | parent | Execution and artifact invariants | Public stage behavior | Production remains blocked |
| [TechnologyConstraints](TechnologyConstraints/DESIGN.md) | child | Verified snapshot preparation | PDK/LEF to native tracks | No process qualification claim |
| [RoutingGeometry](RoutingGeometry/DESIGN.md) | child | Source-bound access, search and conductor/contact geometry | Bounded native routing | Canonical widths and exact source geometry are required |
| [RoutingSourceAdoption](RoutingSourceAdoption/DESIGN.md) | child | Checked explicit routing source extension | Fresh input revision preserves exact parent geometry | Lineage transport alone grants no adoption authority |
| [LegalPlacement](LegalPlacement/DESIGN.md) | child | Bounded legal-row allocation and characterized pre-route selection | Exact source poses and modeled setup cost | Pre-route cost does not establish routed timing closure |
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

`NativePhysicalDesignExecutor.currentImplementationVersion` owns the default
native algorithm identity used by every stage wrapper. Version 1.2.0 identifies
the exact orthogonal-union PRL spacing enforcement owned by RoutingGeometry. Provenance and the
saved run manifest retain the same version; this identity grants no qualification.
Version 1.8.0 additionally identifies explicit refusal of retained LEF antenna
declarations at the shared ProcessInputs and ProcessGeometry admission boundary.
Version 1.9.0 additionally identifies the characterized pre-route placement profile
and retained source/candidate cost evidence owned by LegalPlacement.
Version 1.10.0 additionally identifies the exact qualified CUT enclosure and
minimum enclosed hole-area admission owned by [ProcessGeometry](ProcessGeometry/DESIGN.md).

Canonical snapshot schema 2 retains standard cell orientation, source-bound process
references, pin layer, row site and fixed-via master. ProcessGeometry admits exact
source geometry before and after mutation. Public bare mutation cannot bypass intake.
The native result's physical reference is JSON for lossless same-source resume; DEF
remains the separate bounded standard interchange artifact.

Request schema 8 (with strict legacy-7 nil-policy admission) and run-manifest
schema 7 consume checked immutable
[PDK identity schema 2](../../../PDKKit/Sources/PDKCore/Identity/DESIGN.md).
[TechnologyConstraints](TechnologyConstraints/DESIGN.md#source-routing-width-policy)
owns optional per-layer source-default width selection and its backward-compatible
uniform numeric behavior. Result schema remains 7 and snapshot schema remains 2.
The complete manifest reference is the sole digest authority; metadata is checked
against actual retained bytes by process intake. Other old nested or envelope schemas
are rejected rather than defaulted.

The package design owns stage/result and artifact contracts. With explicit tracks,
every generated signal/ECO/clock segment must lie on at least one declared track
of the same layer and direction: coordinate minus origin is nonnegative, divisible
by spacing and less than count in track units. Checked subtraction rejects overflow.

The store owns anticipated binding construction. Preparation has no persistence
side effects; a store without this capability refuses before any writes. The
executor preencodes all four dependent artifacts, commits one existing atomic
batch, and checks returned bindings and retained bytes before completion.

### Bounded artifact reads

`PhysicalDesignArtifactStore.read(_:maximumBytes:)` is a protocol requirement.
Its default explicitly refuses unsupported bounded access; it never calls the
legacy read requirement. A logical source budget therefore cannot be satisfied
by checking only the declared reference size before an unbounded file load.
The concrete memory and filesystem stores keep `read(_:)` as compatibility
entry points, delegating with the exact reference byte count as their bound.

The memory actor checks cancellation, declared size and actual retained Data size
before digest work or returning the owner. The filesystem store uses the fixed
CircuiteFoundation FileSystem root capability and exact-reference read session.
The existing project-root relative path mapping is retained; the store registers
that actual root/path with the lower capability without conferring authority on
an input root label. Containment compares the canonical filesystem path itself:
the root path is admitted independently of a URL's directory representation flag,
and descendants must start with the root path plus a separator. This admits legal
flat artifacts even when the root URL was formed without a trailing slash; path
normalization, symlink checks and outside-root refusal remain unchanged.
Standard no-follow traversal and regular-file admission,
actual file-size preflight, chunked digest verification and generation-change
checks belong to that lower owner. An enlarged replacement or growth cannot
cause whole-file materialization outside the selected bound.

Returned Data is accumulated only from admitted pages, checking each page against
the remaining exact byte count before append. The caller-facing Data boundary
requires this bounded copy; page storage is retained only during its append.
The completed receipt, returned byte count and digest must all match the binding.
The operational page ceiling is at most one MiB, clamped to the exact content
size; page/work ceilings are checked arithmetic derived from that size. No new
wall-clock timeout is inferred by this byte-only API; Task cancellation remains
checked before acquisition, during lower digest work and between pages. Empty
content with a zero bound remains valid: the lower positive metadata budget of
one cannot admit body bytes because exact expected size zero is checked first.

Each read owns one capability/session and awaits both termination receipts on
success and failure. Close failure is explicit and retains any original failure.
Cleanup waits are not skipped by Task cancellation. A path-precheck refusal remains
`invalidPath`; a descriptor-relative lower intake refusal is `readFailed` retaining
the lower cause, including symlink traversal. Neither classification admits bytes.
No descriptor/session escapes
the call, no shared state is added to the filesystem value and the memory store
keeps actor isolation. Byte and page bounds do not measure allocator overhead or
process RSS. The bounded-store regression suite covers protocol dispatch/default
refusal, actual filesystem enlargement and nonregular inputs, exact digest/count,
zero/exact caps, and cancellation without introducing an unbounded fallback.

Fill uses actual retained conductor footprints and exact source OBS/PORT/contact
polygons for clearance. Existing fills also satisfy pairwise clearance. Density
is the configured fill-area ceiling in each configured window, without a foundry
minimum-density claim. DEF FILLS retains every layer and rectangle. Redundant
fixed contacts require positive-area connection to same-net retained metal on
both routing layers; a displaced contact cannot become success from origin
proximity alone. New contacts satisfy source cut spacing before publication.
Source-free contacts without resolved footprints refuse this operation.

Source-bound power planning routes existing explicit SPECIALNETS power inputs
through the finite special router. It cannot fabricate top ports or select layers
from index parity. Unsupported synthetic source-bound grid requests refuse.
Antenna and hotspot measurement use [RepairMeasurement](RepairMeasurement/DESIGN.md).
Stage III never treats scalar ratio arithmetic or a resolved flag as physical completion.
Canonical DEF cell admission and declaration grammar are owned by
[DEFImport](DEFImport/DESIGN.md).
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
closure remain separate. Source-bound antenna protection uses the exact device and
NativeDRC diffusion rule contract in [RepairMeasurement](RepairMeasurement/DESIGN.md).
A rule verdict never fabricates a numerical ratio or process qualification.

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

Before placement or ECO cell changes discard retained special-net conductors, RoutingGeometry
admits that deletion set against its finite mutable routing profile. FIXED/COVER,
SHAPE ownership, missing width, implicit generation width and special contacts
cannot be erased by invalidation and then appear eligible for ordinary routing.
Successful cell geometry changes publish a candidate with `requires_routing`,
empty old conductors and no verified repair proof. Placement validity does not
establish restored connectivity. Source-qualified routing and subsequent independent
DRC/LVS/PEX/timing observations refine that candidate; production remains blocked.

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

## Host serialization dependency adoption

LogicDesignReference host encoding is supplied by LogicDesignSerialization.
The portable LogicIR value remains independent of Foundation and codecs.
This dependency adoption preserves request semantics and exact content identity.

Manufacturing-grid legality and exact source reconstruction are owned by
[ProcessGeometry](ProcessGeometry/DESIGN.md), including technology-only Native
execution. Executor admission checks output before immutable persistence.
