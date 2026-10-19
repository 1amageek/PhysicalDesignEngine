# Legal Placement

## Purpose and Scope

Own bounded deterministic legal-row allocation for native placement.
Parent: [PhysicalDesignCore](../DESIGN.md). No children. Own characterized
pre-route timing-driven candidate selection in addition to legal-row allocation.
Routing, post-route timing closure, CTS and production qualification remain separate.

## Responsibilities and Boundaries

Consume validated rows, actual cell bounds, blockages and exact process geometry.
Search legal source orientations and site locations while preserving locked cells.
ProcessGeometry owns source projection, symmetry and pin reconstruction. The native
executor owns input identity, final admission and immutable artifact publication.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent / used by | Native mutation and persistence | Stage composition | A rejected allocation publishes no successful revision |
| [ProcessGeometry](../ProcessGeometry/DESIGN.md) | depends on | Exact dimensions, compatible source sites/orientations, reference ports | Process geometry authority | Retain pin identity and net while changing source-derived pose |
| [Package](../../../DESIGN.md) | used by | Placement wrapper and CLI | Public invocation | Geometry success cannot promote timing or production claims |
| [Timing STA](../../../../TimingEngine/Sources/STAEngine/DESIGN.md) | depends on | Source-qualified sequential eligibility, strict samples, propagated clocks and complete required-check coverage | Characterized candidate admission and cost | Reported critical paths alone do not establish complete coverage; pre-route RC is not extracted routing |
| [LEF source](../../../../swift-mask-data/Sources/LEF/DESIGN.md) | depends on | Retained electrical units, routing sheet resistance, area/edge capacitance and width | Exact corner-selected source wire estimate | Unit declarations specify precision, not coefficient multipliers |
| [PEXParsers](../../../../PEXEngine/Sources/PEXParsers/DESIGN.md) | depends on | Canonical ParasiticIR-to-SPEF writer | Retained candidate RC input | Calculated pre-route elements do not claim extraction |

## Architecture

```text
Native executor -> source admission -> LegalPlacement allocator
    -> occupied intervals + aligned boundary events per row/orientation
    -> actual legal cells and pins -> geometry-only output
    -> optional exact placement characterization
        -> legal same-size movable pose swaps -> source pin projection
        -> explicit pre-route star capacitance -> exact NLDM/SDC setup cost
        -> strictly improving candidate -> output source admission -> retained artifacts
```

## Contracts and Invariants

- Rows and cells require positive, representable geometry and a core. Locked cells
  remain byte-equivalent values, placed on compatible rows, inside the core and
  outside blockages; overlapping locked cells fail before candidate search.
- Movable cells are processed by stable cell ID. Each cell searches all rows by
  stable row ID, retaining its incoming orientation first. With process sources,
  remaining standard orientations are tried only when exact master SIZE, symmetry
  and site compatibility admit them. Without sources only the supplied pose is
  available as geometry smoke, never process closure evidence.
- A candidate starts at the row origin or at an occupied interval's right boundary,
  aligned upward to the row site lattice. Blockages, locked cells and already
  allocated movable cells contribute actual rectangles. Placement spacing applies
  to newly allocated candidates relative to occupied cell bounds. Site-count-sized
  arrays and iteration over every site are not used.
- Candidate geometry must fit its row/core and avoid occupied rectangles. This is a
  deterministic incremental allocator, not a global optimal packing claim; failure
  reports that no candidate is available under the retained allocation order.
- Translation retains selected source pin offsets. Orientation changes reconstruct
  connected pins using exact source PORT geometry, retaining ID, cell ID, name and
  net ID. Pose changes invalidate stale routes, clock trees and dependent proofs.
- The automatic candidate ceiling is the checked structural bound
  `cellCount * rowCount * 8 * (blockageCount + cellCount + 1)`.
  `configuration.maximumPlacementCandidateChecks` is an optional positive caller
  ceiling; its effective value is the smaller of that ceiling and the structural
  bound. Omission selects the structural policy, not an arbitrary numeric default.
  Counts and the effective ceiling are exposed as raw placement metrics.
- Arithmetic overflow, exhausted candidate budget, cancellation and unavailable
  geometry are explicit failures. Neither an exhausted search nor a geometry
  observation establishes timing-driven or production closure. Geometry-only
  execution retains `timing: notApplicable` and `production: blocked`.

### Characterized Pre-route Selection

The optional placement timing reference selects one immutable profile artifact and
caller-defined cumulative source-byte, deadline, path-state and path-work limits.
The request and run manifest retain that reference; every referenced source must
also be an exact input binding. The profile binds the exact manifest, selected
Liberty/technology-LEF assets and RC corner, observed operating condition and
source layer width. Source identity, manifest asset membership/digest/PVT,
strict source characterization and explicit LEF capacitance-unit admission precede
candidate selection. Missing or mismatched facts fail explicitly.

The legacy schema-1 cost model is `lefGroundCapacitanceStarV1`: each non-power/non-clock
signal net has one actual driver and explicit sinks. A source-derived pin point
provides each endpoint. Each driver-to-sink Manhattan branch contributes ground
area/perimeter capacitance using the selected source metal, admitted width and
exact selected-LEF area/edge coefficients and explicit picofarad units. The unit declaration factor is a precision declaration; it is never a capacitance multiplier. Branches are additive virtual wires; shared branches,
resistance, coupling, obstacle avoidance, vias and detailed routing are not modeled.
This is an explicit pre-route load estimate consumed by characterized STA, not a
claim about actual routed capacitance or sink delay. Invalid material/range or
ambiguous topology is unsupported rather than a zero-load fallback.

The retained mapped source is parsed by TimingDesignParser. Schema 1 requires its
existing combinational signal inventory. Schema 2 uses the exact signal inventory
and separate supply inventory in [Source-bound Terminal and Supply
Classification](#source-bound-terminal-and-supply-classification). Original mapped
source identity remains retained even when explicit supply connections are excluded
from the timing graph. NativeSTAEngine owns Liberty, SDC, sequential/control truth,
functional arc, slew/load and timing-check semantics. Missing metrics, unconstrained
coverage, unknown characterization, blocked execution and exceeded lower limits
cannot become numerical cost values.

Legal allocation produces a baseline. A single stable-ID ordered pass evaluates
same-size movable cell-pair pose swaps against the current accepted candidate.
Physical occupancy is unchanged by each swap. Each new pose must retain its source
SITE/orientation admission and reconstruct exact connected PORT geometry. Locked
cells are never candidates. A candidate is accepted only when its measured worst
setup slack strictly improves without increasing measured maximum row utilization; a tie retains the current candidate. This is bounded
local improvement, not global placement optimality. The existing candidate ceiling
is shared by legal allocation and candidate checks, with no guessed search-count
default. The characterized structural ceiling adds one baseline timing evaluation
and the checked movable-pair count to the legal allocator ceiling. One shared
Liberty resource accountant charges actual Liberty parser work, one logical byte-work unit for each retained source intake/non-Liberty transform and encoded candidate evidence, and source work and reserves each caller-selected
per-analysis path-work ceiling against the total work budget. Work units are conservative logical charges, not CPU instruction counts. Live-storage limits cover the lower Liberty owner logical payload/reservations and retained source buffers; they are not an RSS claim. Active path states
are bounded per sequential analysis; encoded retained evidence has a cumulative
byte ceiling. One deadline spans intake, baseline and every analysis. Exhaustion, deadline and cancellation reject the whole operation instead
of publishing a partial search.

For schema 1, optional required minimum setup slack applies to the selected modeled result. The
retained placement evidence binds the profile, baseline/selected snapshot and
TimingDesign digests, exact STA results and candidate decisions. Geometry identity covers top name, units, die/core/rows/cells/pins/nets/blockages and exact process sources; metadata and derived proofs are excluded to prevent self-reference. Each embedded TimingDesign re-encodes to the exact STA input reference. This is retained raw analysis, not an independent STA replay or qualified acceptance. Timing capability
remains blocked for post-route closure and production remains blocked. No profile
is consumed during geometry-only placement; characterized placement requires it.

### Source-bound Sequential Pre-route Profile

Schema 2 selects `lefDistributedRCStarV2`, source-propagated primary clocks and
complete source-applicable timing checks. Schema 1 remains the explicitly limited
combinational contract; neither old profile bytes nor old evidence grant the new
coverage. Generated/gated clock and sequential semantics are admitted only through
the lower source-qualified eligibility contract, never by pin-name inference or
Physical-side truth reconstruction. FF/latch, launch/capture, enable/reset and
conditional checks require actual lower support before they can establish this
profile's completion. A constant D input does not establish a constant state output.
Schema-2 `operatingSupplyAssumptions` are explicit conditional inputs binding each
instance/cell/corner/library artifact/pin/source PG type to a supplied binary value.
They are passed unchanged to lower source admission and bound into candidate
configuration/evidence. PG names or types never infer a value. These assumptions
do not measure a physical supply or upgrade source-only supply coverage.
The profile also retains explicit `STADistributedRCOptions`: finite step, horizon,
crossing tolerance, refinement, node and step ceilings. No numerical defaults are
invented by placement. Execution and prepared source-evidence validation each
precharge one caller-selected analysis-work ceiling and share the same cumulative
accountant/deadline; validation does not reset or increase the caller allowance.

The exact selected routing layer must supply finite positive sheet resistance in
ohms per square, explicit finite nonnegative area/edge capacitance in pF units with
a positive sum, and explicit finite positive resistance/capacitance unit precision.
The width must satisfy source MINWIDTH/width and MAXWIDTH. Missing coefficients,
units, ambiguous drivers or nonrepresentable arithmetic are explicit failures.
Each source-pin Manhattan branch uses R = sheetResistance * length / width and
C = (length * width * areaCapacitance + 2 * (length + width) * edgeCapacitance) *
1e-12, represented by a resistor and two half-ground-capacitances. Branches are
additive virtual wires; sharing, obstacles, vias, coupling and actual routed metal
are not inferred. A zero-length branch retains both terminal identities and an
explicit calculated zero-resistance element with zero wire capacitance. Lower
exact same-net ideal-short coalescing owns the operator; epsilon resistance,
terminal-name collapse and dropped incidence are not substitutes.

LegalPlacement produces a calculated ParasiticIR and explicitly selects the SPEF
writer's canonical terminal-token profile; generated private pin tokens are not
rewritten by Physical or silently interpreted as Timing endpoints.
The exact candidate SPEF, projected TimingDesign, geometry digest, profile/model
identity, manifest/Liberty/LEF references and RC corner are bound together. Lower
`preRouteProjected` provenance distinguishes these inputs from extracted RC and
owns the composition of graph/pin capacitance and SPEF load without double counting.
Lower propagated-clock observations must cover every required mode/corner/root/
receiver/rise-or-fall edge with actual arrival and slew and the same candidate RC
binding. Ideal-clock observations cannot discharge that requirement.

Required-check coverage is independent of `maxPaths`: lower source-qualified keys
identify mode, corner, instance, constrained/related pins and edges, check kind,
source arc and condition. Each key has a measured pass/fail or a source-proven
not-applicable outcome. Excluded or unknown required checks do not pass admission;
static data does not remove required control checks. Lower owns strict source-domain
samples for combinational/clock-to-Q propagation and signed sequential constraints;
Physical does not reconstruct these from truncated path stages.
After exact prepared-owner validation, placement also consumes lower
`sourceNotApplicable`, `staticControlNotApplicable` and
`staticStateNotApplicable` check statuses. These carry source-owned absence,
control/state and static-output witnesses; they are not derived from pin names,
polarity or missing numerical values in Physical. Initial-state/reset assumptions
and exact PG conditional inputs remain bound. Measured clock/pulse requirements
are not removed by a static state output.

Baseline and adopted candidates require complete non-setup coverage and passing
required hold/recovery/removal and other applicable non-setup checks. Initial
negative setup slack may serve as an improvement cost. An evaluated swap with a
known check failure retains its raw result and rejection reason and is not adopted;
missing/unknown coverage, cancellation or exhausted resources fail the operation.
Among admitted candidates with measured setup, the existing stable pair order and
strict setup-slack improvement rule remain. The final selected measured candidate
must have setup slack at least max(0, the supplied minimumSetupSlackSeconds).
Lower `setupApplicability` is consumed only after prepared validation. A mixed
measured/static result uses its actual finite aggregate setup slack. An unknown
disposition or missing measured metric is a failure. When lower proves that every
required setup role/endpoint is discharged by exact static/nonapplicable witnesses
and no active setup path exists, `sourceNotApplicable` retains the legal baseline
without pose search and records `baselinePreservedNoApplicableSetup`. Its slack
stays nil; no zero, improvement or numerical threshold satisfaction is invented.
Any explicitly supplied minimumSetupSlackSeconds, including zero or a negative
value, requires a finite metric and therefore refuses this all-static case.
Only omission permits the source-proved nonapplicable objective. All other required
check, clock, source and resource admission remains in force. Failure publishes no successful
revision. A failed bounded search does not prove that no legal solution exists.
The native placement composition retains this selection disposition in metadata
and omits initial/selected setup metrics for the nonapplicable baseline. Legacy
and measured selections still require actual finite values for both metrics.

Version-2 evidence retains the original input graph, classified terminal/constant/
sequential/supply bindings, exact projected graph and SPEF bytes/references, lower
clock/check coverage and raw candidate decisions. Reload verifies those identities
and the selected candidate's admission under the same profile version. Raw results
are retained analysis, not independent replay or qualification. Request/manifest
envelopes continue to retain the versioned profile reference without promoting old
evidence. Timing/production qualification remains blocked; distributed-RC
pre-route prediction does not close post-route timing or physical clock signoff.

The schema-2 execution composition classifies immutable connectivity once before
pose search; a same-size pose swap changes source pin positions, not the retained
terminal/net/source identities. Each candidate projects fresh RC and prepares STA
with strict source evidence, all supported analysis kinds and the explicit supply
conditions. NativeSTAEngine's `STASourceEvidenceValidating` contract must validate
the result against that exact prepared owner before placement consumes role status,
endpoints or clock observations. Each execute and validation replay reserves its
analysis ceiling separately; the second operation shares the existing source
accountant and deadline. This validation is part of admission, not a self-reported
complete flag or a second independent tool qualification.

Evidence decodes the exact retained schema-2 profile bytes to its typed contract,
re-encodes the projected graph, and hashes the exact profile/SPEF bytes against
their retained input references. Its synchronous
check covers every schema-2 candidate graph, including rejected and nonselected
candidates: encoded byte count, digest and that candidate's exact STA input binding
must agree. Selection does not exempt a retained raw graph from this join. The
geometry check validates these structural joins and the selected non-setup/setup
policy. It consumes Lower's common structural setup-applicability validator for
each schema-2 raw payload: the declared objective must agree with its retained
roles, endpoints, paths and metric. Changing only the objective flag, aggregate
metric and placement disposition cannot reinterpret measured setup as source
nonapplicability. This is structural consistency, not source requalification;
Physical does not infer source state/control truth. The check does not rerun
source admission or grant qualification merely by JSON
decoding. Fresh API execution performs prepared-owner validation before publication.
The original mapped artifact reference, classification and all analyzed candidate
inputs remain available to a caller that independently prepares/replays them.

### Actual Sky130 Placement Verification

[ActualSky130SequentialPlacementTests](../../../Tests/PhysicalDesignEngineTests/ActualSky130SequentialPlacementTests.swift) exercises the host API and built CLI with
two movable `sky130_fd_sc_hd__dfxtp_1` cells and a primary propagated clock. The
application is a two-register feedback circuit: each Q drives an actual D input,
and the top output observes one of those nets. Actual source pin capacitance owns
the sink load; no fabricated external load or wire length admits an NLDM query.
Explicit SDC stimulus and normal-power conditions remain caller inputs. Every declared source PG pin receives an explicit value for each
instance: VPWR/VPB are one and VGND/VNB are zero. These four declarations per
instance are validated conditions, including nwell/pwell roles; they are not
measured supply connectivity.

Selected complete cell/template/header Liberty and cell LEF bytes reuse the
Native CTS source-selection report. Technology bytes reuse the original antenna
fixture's exact ranges, including selected routing, cut, antenna and AREA laws.
The test checks original-file and selected-byte digests before constructing fresh
manifest/profile/request bindings. Selection is explicit: omitted whole-source
manufacturing/current-density/generated-via declarations do not become supported
or qualified through these selected inputs. Source files and numerical values are
not rewritten. Source-only PG declarations remain unmeasured physical supplies.

The placement profile uses actual selected LEF sheet resistance and area/edge
capacitance with their declared units, selected nominal RC corner and actual TT
Liberty. It does not reuse the CTS fixture's analytical extraction model or claim
post-route RC. A bounded API run and independent CLI run must retain the same
candidate geometry/graph/RC and complete Lower source/check/clock evidence after
filesystem save/reload. Unknown/stale/contradictory evidence must still refuse.
Failure retains the actual diagnostic rather than modifying source laws, loads,
budgets or geometry to manufacture a pass.

This closes only the real-source host placement observation. Production intent
remains explicitly blocked. Real CTS RC provenance, routed-candidate extraction,
retained-tree recharacterization, post-route setup/hold/control closure and tool
qualification remain mandatory, separate completion obligations.

The shared Lower structural check scans R roles, C coverage entries, E endpoints
and P paths with logical work bounded by 3R+C+E+P+1 and storage/state slots bounded
by R+C+E+P+1. Lower checks these against the retained execution limits before
temporary storage growth. Fresh placement adds the checked linear work bound to
its existing role-join charge before invoking the check; no caller ceiling changes.

For T signal terminals and B driver-to-sink branches, projection pre-admits checked
node <= T and element <= 3B bounds, source/name byte bounds, writer work and live
payload/output reservations before growth. Branch construction checks cancellation.
SPEF bytes, coverage and candidate evidence consume the same cumulative input/work/
live/evidence/deadline limits; caller ceilings are unchanged. Conservative logical
work/storage accounting is not an allocator or RSS guarantee. Endpoint aliasing,
if required, must preserve physical terminal identity within those same bounds.
Schema-2 retained candidate/header payload charges stay live for the accountant's
invocation lifetime. Each candidate is charged inside a one-field array envelope
with the same pretty-printed nesting as the full evidence; redundant wrapper bytes
are conservative. The header bound uses the maximum UInt64 work-counter spelling
and array separators so retaining profile bytes/classification cannot escape the
cumulative evidence ceiling. Writer scratch reservations end after conversion;
the candidate's exact bytes remain covered by retained evidence storage.

## Runtime Flows

Admit exact state -> validate fixed occupancy -> derive ceiling -> allocate each
movable cell -> relocate/reconstruct pins -> validate real output geometry ->
optionally load exact characterization -> evaluate baseline -> bounded legal swaps
and actual STA -> require selected modeled constraints -> retain source-bound
JSON/DEF/diff/manifest and candidate timing evidence. All candidate state is invocation-local; rejection
retains the input and publishes no successful revision.

## State, Ownership, and Lifecycle

The allocator and its protocol are Sendable immutable values. The invocation resource accountant uses one Synchronization.Mutex<State> on every compiled target, with short in-memory access only; no await, I/O, callback or conditional raw-state branch occurs under the lock. Owned source/storage reservations outlive each borrow and release through the lower ownership contract. Generated candidate TimingDesign availability denotes an invocation-local memory service backed by the actual reader; its complete data is embedded in retained evidence for reproduction, not advertised as an external retained file. Candidate occupancy,
counters and output state belong to one invocation; no target-dependent shared
storage or isolation is introduced.

## Failure, Concurrency, and Constraints

Typed placement failures become structured blocked stage diagnostics. Lower STAPreparationError, STAExecutionError, LibertySourceError and TimingCharacterizationError remain retained associated causes in the placement failure contract; missing analysis cannot be mislabeled as a geometric success. Cancellation
remains cancellation. Candidate event storage is bounded by occupied rectangles,
and candidate evaluations by the checked ceiling. Collision checking cost also
depends on supplied occupancy; no measured large-design throughput claim is made.

## Verification and Change Impact

LegalPlacement behavioral tests run actual native source intake and the CLI.
Counterexamples cover locked occupancy, a narrow legal site after a blockage and
an alternating-row orientation requiring source pin reconstruction. Rejections
cover capacity, explicit budget, invalid locked geometry, overflow and cancellation;
retained artifacts and exact process/pin/net identities are checked.
CharacterizedPlacementTests use exact selected Sky130 Liberty/LEF source blocks and an explicit ground-capacitance estimate. The selection-report records original digests, byte ranges and excluded laws, with the original technology bytes retained. This is limited process coverage, not fully admitted original PDK input; original rule-bearing technology source remains a refusal case. They require
actual setup-slack improvement; changing the critical SDC endpoint with unchanged
geometry/total wirelength must change the selected pose. API/CLI retain the same
candidate/profile/timing identities. Missing/stale characterization, logical-net
mismatch, illegal source orientation, exceeded work/deadline and cancellation
publish no artifacts. Existing
placement/source-consumption regressions verify the shared native mutation path.

### Source-bound Terminal and Supply Classification

`NativePhysicalDesignPlacementTerminalClassification` owns the invocation-local
binding of the retained TimingDesign, OwnedLibertySource, admitted ProcessInputs,
ProcessGeometry and physical snapshot. It returns the signal graph and Codable
terminal, constant and raw sequential-source records. It retains the Liberty owner
and live-storage reservations. It neither parses another source format nor grants
sequential timing eligibility; that decision belongs to the
[Timing contract](../../../../TimingEngine/Sources/TimingCore/DESIGN.md).

```text
exact Liberty + LEF + physical incidence + original TimingDesign
    -> source-bound terminal classification
        -> unchanged signal connectivity/constants -> lower timing admission
        -> separate supply inventory + source-only declarations -> binding evidence
```

LEF USE POWER/GROUND is supply-role authority. Omitted USE has LEF's ordinary
SIGNAL meaning; CLOCK remains a signal and ANALOG/FEEDTHRU is unsupported here.
Signal direction must agree between exact Liberty pin, LEF pin and physical pin;
top ports use their retained explicit surface/direction. Names never establish
direction, bus width, clock/control, supply domain or polarity. Bit identities
remain exact names; no bus expansion is inferred. Physical incidence is reciprocal
and unique. Every logical signal terminal, instance/master, top port and net has
one physical binding. Only explicitly classified supply connections, ports and
nets are removed from the lower signal graph. Mixed signal/supply, mixed power/
ground, conflicting explicit DEF USE, missing required source or unknown role
fails before timing. Physical PG absent from the original graph is retained
separately, rather than synthesized as a signal connection.

| Coverage | Guarantee | Timing meaning |
|---|---|---|
| boundSignal | Exact logical/physical/source terminal | Requires lower admission and measured coverage |
| boundSupply | Exact physical occurrence and source USE | Unmeasured supply inventory |
| sourceOnlySupply | Exact LEF declaration without physical occurrence | Unconnected and unmeasured; fills no required coverage |
| Unknown required binding | Explicit failure | No zero-delay or successful coverage fallback |

Explicit logical literals and source-proven inputless literal tie outputs have
distinct constant records. A constant data net does not make a sequential output
constant. Raw FF/latch declaration offsets are retained with the source owner;
control expressions, startup, clear/preset and enable eligibility are not inferred
from names or the simplified compiled model. Supply is never a logical literal
or a measured zero-timing path.

The existing cumulative placement accountant charges each traversal and checked
logical storage envelope before growth, and checks cancellation/deadline. The
envelope includes graph copies, indices and record/string payload; it is not an
allocator/RSS guarantee. Upper placement evidence owns exact profile, original/
projected graph, Liberty and LEF artifact identities and encodes these records
under its versioned schema. Reload must revalidate their source bindings; old
evidence is not reinterpreted as this new coverage contract.

[PlacementTerminalClassificationTests](../../../Tests/PhysicalDesignEngineTests/PlacementTerminalClassificationTests.swift)
owns signal/supply separation, exact directions/incidence, mixed-role refusals,
source-only PG, literal tie versus constant D/dynamic Q, raw sequential references,
storage/work exhaustion and cancellation counterexamples. Upper API/CLI tests own
persisted binding-record/digest equality after filesystem reload; helper success
alone establishes neither timing eligibility nor qualified process coverage.
