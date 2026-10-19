# ClockTreeSynthesis

## Purpose and Scope

Own source-bound native clock-tree candidates and characterized passive linear RC
transient observations. Parent: [PhysicalDesignCore](../DESIGN.md). No children.
This contract replaces the legacy length-only characterization using the verified
TimingEngine strict characterization and CoreSpice bounded passive CPU transient
contracts. The legacy arbitrary-byte and constant-delay execution is rejected.

## Responsibilities and Boundaries

Own exact clock identity, explicit waveform/model selection, bounded topology
construction, source geometry projection, lower-contract composition, threshold
measurement, candidate constraint admission and retained model observations.
Do not invent RC coefficients, source electrodes, clock-generation waveforms,
Liberty table values, missing corners or nonlinear cell current laws. TimingEngine
owns strict Liberty admission; PEX owns RC materials, mesh and electrodes;
CoreSpice owns transient integration and numerical solve. Physical signoff, tool
trust and foundry qualification remain separate authorities.

## Related Designs

| Design | Relationship | Contract used | Caution |
|---|---|---|---|
| [PhysicalDesignCore](../DESIGN.md) | parent | Exact request and atomic artifacts | Model computation is not signoff |
| [ProcessGeometry](../ProcessGeometry/DESIGN.md) | depends on | Selected masters, orientations, PORT/OBS and fixed via shapes | A reference pin point is not an electrode |
| [LegalPlacement](../LegalPlacement/DESIGN.md) | depends on | Occupied-interval candidates and work ceilings | Existing cell poses and identities remain fixed |
| [RoutingGeometry](../RoutingGeometry/DESIGN.md) | depends on | Width-aware source access and bounded routes | Construct the candidate before publishing its tree |
| [TimingEngine](../../../../TimingEngine/DESIGN.md) | depends on | CharacterizedTimingLibrary: selected pin capacitance, thresholds, checked four-LUT propagation | Table transition is a measured duration, not a waveform shape |
| [PEX electrical model](../../../../PEXEngine/Sources/PEXCore/ElectricalModel/DESIGN.md) | depends on | Exact SI law, PVT, calibration identities and applicability | Calibration identity does not qualify coefficients |
| [PEX mesh](../../../../PEXEngine/Sources/PEXNative/SheetExtraction/DESIGN.md) | depends on | Physical RC operators and pin incidence | Incidence alone does not impose an electrode |
| [PEX electrodes](../../../../PEXEngine/Sources/PEXNative/ElectrodeConstruction/DESIGN.md) | depends on | Explicit exposed faces and finite sheet contacts | No terminal-name-induced conductivity |
| [CoreSpice analysis](../../../../CoreSpice/Sources/CoreSpiceAnalysis/DESIGN.md) | depends on | Public strict PWL, bounded passive CPU transient, accepted time axis and checked result | No GMIN/source recovery or Metal qualification is inferred |

## Architecture

```mermaid
flowchart TD
    Inputs[Exact manifest / LEF / Liberty / RC / schema-3 clock model] --> Admission
    Admission --> Candidate[Explicit topology + bounded placement and source routing]
    Candidate --> Capture[Actual PORT / width-aware wire / fixed via conductor capture]
    Capture --> PEX[Existing mesh + explicit electrode contacts]
    PEX --> Load[Downstream modeled capacitance]
    Load --> Cell[Range-checked Liberty delay and transition]
    Cell --> Driver[Caller-declared PWL shape / threshold scaling and alignment]
    Driver --> Transient[Existing bounded CoreSpice passive CPU transient]
    Transient --> Measure[Saved waveform threshold crossings / refinement agreement]
    Measure --> Gate[Sink delay / slew / load / latency / skew constraints]
    Gate --> Publish[Validated clock tree + JSON / DEF / diff / manifest]
    Admission --> Failure[Typed blocked or cancelled / no successful artifacts]
    Gate --> Failure
```

## Contracts and Invariants

The schema-3 clock model requires an explicit method, exact process/version/corner,
source asset IDs, source digests, clock roots, original sinks, topology profile,
source PWL waveforms, buffer waveform shapes, electrodes, constraints and numerical
limits. Schema 1 and its arbitrary-byte/length/constant-delay semantics are rejected.
Schema 2 remains explicitly admitted with absent/empty top-port electrode data and
its original cell-output-root semantics; neither its retained version nor source
digest is rewritten. Schema 3 requires an explicit top-port electrode table,
including an empty table for a cell-root-only model.
Every selected Liberty/RC asset belongs to the exact manifest corner and matches
its retained binding by format, role, digest and byte count. RC selection retains
the exact PVT and parameter dictionary; Celsius-to-kelvin conversion is explicit.
Every calibration content identity selected by the RC model has a retained input
binding and verified bytes; this proves input integrity, not calibration accuracy.
Units are seconds, volts, farads, ohms and explicit integer DBU. No nominal corner,
unit, pin direction, buffer master or root waveform is inferred.

Every clock root has one explicit canonical driver and at least one exact cell
input sink. A driver is either a cell output or a top-level input with an actual
retained `PhysicalDesignTopPort`. The declared source must be the sole functional
driver of its clock net. The actual top-port USE remains SIGNAL or CLOCK; clock meaning comes from the
explicit model and canonical clock net, not a metadata rewrite. Primary-input
roots require schema 3 and one explicit
`PhysicalDesignClockTopPortElectrode`, keyed by canonical pin ID, whose faces are
in the snapshot's world DBU frame. Those faces must be covered by the actual
retained top-port metal and independently pass the lower PEX exposed-face checker.
The source is the caller's ideal prescribed PWL boundary, without an invented
external driver cell, Liberty capacitance, delay or slew. Its source terminal is
excluded from receiver pin-capacitance loading. Other top ports contribute their
retained metal to conductor capture, including the quiet-boundary network.
Top-port electrode identity must exactly cover the configured primary roots; no
unused/foreign electrode, missing surface, duplicate driver or implicit source is
admitted. Connected
sink pin names, directions and clock semantics agree with selected source masters
and strict Liberty. Selected sink cells require capacitance/clock admission;
selected propagation buffer cells additionally require the unique supported
combinational arc and all four checked LUTs. Unused DFF clock-to-Q/constraint arcs
cannot become evaluated CTS buffer arcs. A retained tree cannot be recharacterized
using a preceding estimate; this execution profile requires a pre-CTS snapshot.

Topology selection is explicit and finite: direct, one exact buffer per original
sink, or direct followed by that buffered candidate. The caller supplies the
buffer master whenever buffering is permitted. Distance thresholds do not select
an electrical topology. New IDs cannot collide with retained entities. Existing
cell poses/orientations, original source/sink identities and unrelated net
membership remain fixed. Buffer placement uses the existing legal allocator with
original cells locked; restored lock flags remain identical to the input.
Source routing receives only the explicit clock family, with trees unpublished.
Actual source PORT access, per-segment width and fixed via identities survive
JSON and supported standard DEF. Changed geometry invalidates preceding proofs;
unrelated evidence cannot be relabeled as fresh verification.

Conductor capture includes the generated clock wires with their actual width and
the shared [qualified endpoint footprint](../RoutingGeometry/DESIGN.md), exact transformed PORT metal, fixed via metal/cuts, and
retained modeled conductors. Pin labels do not add ideal wires. Explicit electrode
faces are expressed in the capture's DBU scale and must be covered exposed faces
of the selected source PORT/conductor; mesh refinement does not change their
physical identity. Missing, overlapping, floating, shorted, disconnected or
ambiguous terminal contacts fail. The existing PEX law and dimensional ranges
apply unchanged; no new capacitance law or aggregate via resistance is introduced.
`PhysicalDesignClockNumerics.maximumCellSpanDBU` is a positive span in the source
`PhysicalDesignSnapshot.unitsPerMicron` scale. Projection converts that span to
`capture.coordinateUnits` using the same exact positive integer capture/source
multiplier used for electrode coordinates. The checked product must fit `Int32`
before PEX mesh construction; failure is a typed model rejection. A refined
capture grid therefore preserves the caller's physical mesh resolution and does
not consume a finer-mesh transient budget merely because pin capture refines DBU.
The caller supplies electrode profiles by exact master and PORT name in the
canonical N-oriented, ORIGIN-adjusted master DBU frame. ProcessGeometry's existing
orientation/placement transform applies them to each occurrence, including newly
placed buffers. No nearest face or representative pin point selects a boundary.
For a selected cell PORT containing multiple rectangles, all original metal pieces
are retained. Caller-declared transformed electrode faces must fit inside one
unique actual access-layer rectangle. That exact rectangle supplies nonconducting
pin incidence only; every retained PORT piece must belong to the same captured
component. The existing PEX owner still validates actual exposed contacts, never a
bounding box. Multiple possible incidence rectangles, disconnected pieces and
faces spread across several rectangles are explicitly unsupported in this bounded
profile. General union-shaped pin incidence is not claimed. Each added rectangle,
face and captured component/footprint probe consumes the caller's cumulative
projection-record allowance and checks cancellation; no unbounded source scan is
introduced.

The supported method is passive linear RC transient with an explicit quiet-other-
conductor boundary. Other conductors are held at the declared reference voltage;
their coupling capacitors contribute to the active network without changing their
source coefficients. Active internal capacitors retain both endpoints. Coupled
activity/crosstalk and nonlinear/CCS driver behavior are unsupported. The source
electrode is driven by its caller-supplied ideal PWL. Initial conditions explicitly
represent its settled initial level; numerical leakage or convergence recovery
cannot silently change the circuit.

Buffer composition uses the declared NLDM lumped-load approximation: output load
is the retained downstream ground/quiet-coupling capacitance plus strict Liberty
sink capacitance. Cell delay and output transition are evaluated in seconds within
all LUT axis ranges. The caller supplies distinct normalized monotonic rise/fall
PWL shapes. If their lower/upper threshold crossings are `uL` and `uU`, scale time
by `T = transitionSeconds / (uU - uL)`. Align the output-delay-threshold crossing
to the measured input-delay-threshold arrival plus the evaluated cell delay.
Scale voltage to the exact supply. This shape selection is retained, never derived
from the transition duration. Invalid shape, range, alignment or horizon fails.

The clock requests trapezoidal as `TransientConfig.preferredMethod`. CoreSpice's
linked analysis contract owns checked backward-Euler startup and smooth-history
admission before the preferred higher-order method; the clock does not override
that numerical lifecycle or change tolerances to select a method.
CoreSpice solves the actual admitted RC circuit, not Manhattan distance or a
first-moment shift. In nodal form its passive operator is `C dv/dt + G v = b(t)`;
sheet/cut/contact resistors and both-ended capacitors are stamped by the existing
device/analysis implementation. The finite-volume resolution and numerical
integration policy are recorded. They are approximation controls, not foundry
accuracy certification.

## Runtime Flows

Admit source identity and profile -> construct a bounded topology candidate ->
place and route -> capture geometry -> extract RC and impose explicit electrodes
-> determine modeled downstream loads -> propagate cell LUT/PWL and RC waveforms
in tree order -> measure every original sink -> apply constraints -> validate and
write artifacts. An unsuccessful candidate contributes rejection evidence only.
Clock trees and timing observations are published only for the final successful
candidate after artifact writes complete.

Rise/fall arrival is the appropriate source-library/request threshold crossing on
the actual accepted node waveform; slew is its ordered lower/upper crossing
duration. Latency is relative to the original root's corresponding output-delay
threshold crossing. Latency is a signed difference when distinct input/output
thresholds are declared; a negative crossing offset is not rejected or clamped. Skew is the range of original sink arrivals for the same root
edge. Crossings use retained adjacent samples with interpolation and reject
missing, reversed or ambiguous crossings. Rise/fall loads, cell contributions,
node/terminal identity, sampled brackets and constraint margins remain inspectable.

## State, Ownership, and Lifecycle

Each invocation owns immutable admitted sources and call-local candidates, RC
graphs and waveforms. The existing artifact store owns verified reads and atomic
immutable publication. Cancellation propagates to the lower transient token and
all placement/routing/capture/measurement loops. Acquired lower device sessions
end on success, rejection, failure and cancellation. No shared cache, target-
conditional state, raw pointer ownership or separate host graph wrapper is added.

## Failure, Concurrency, and Constraints

Caller-owned model limits bound source bytes/records, topology attempts, placement
and routing candidates, capture records, mesh nodes/operators/contacts, transient
dimension, attempts, accepted points, saved scalars, work, time horizon, refinements
and measurement scans. Structural ceilings bound finite topology and existing
geometry searches; caller values may lower those ceilings. Arithmetic and
allocation products are checked before work. `PhysicalDesignClockNumerics.captureLimits`
is an optional schema-3 resource profile. Its serializable value adapts the existing
lower capture owner's ten explicit quotas without defining a new geometry algorithm:
hierarchy occurrences/objects/points/depth, decomposition input entries/edge probes/
output bands, technology records, footprints and contact candidate probes. A lower
input entry is a polygon plus each point (each expanded VIA layer rectangle counts
separately); a contact probe is a candidate pair or pin-band/footprint test, including
rejected candidates. Projection records and successful contacts are different units.
The adapter validates each quota and forwards it unchanged; it does not multiply,
reset or silently enlarge caller limits. Schema 2 rejects an explicit capture profile.
When the field is absent, schemas 2 and 3 preserve the existing projection-record and
geometry-probe mapping exactly; raw version/digest and legacy failure behavior remain
unchanged. The fixture profile owner selects explicit operational limits from actual
expanded geometry counts and checked finite candidate bounds. A lower explicit quota
must refuse without publishing candidate artifacts. The same actual-source fixture
runs both API and built CLI with input-entry or contact-candidate quota one; each
must preserve the corresponding lower resource diagnostic and publish no candidate. The selected actual-Sky130 fixture's
single no-relaxation diagnostic measured all-rectangle upper inventories of 12,557
and 23,561 expanded polygons for primary and derived clocks, respectively. The
larger inventory has 94,284 points and seven rectangular selected pins. Its owner
selects checked `inputEntries = polygons + points + 5 * pins`,
`outputBands = polygons + pins`, `footprints = polygons`, and
`contactProbes = polygons * (polygons - 1) / 2 + polygons * pins` ceilings. Existing
hierarchy, edge-probe and technology-record ceilings remain unchanged. These are
fixture operational limits, not universal production defaults or measured runtime
work. The legacy cell-root fixture selects sufficient old record/probe ceilings
under the same legacy units and keeps `captureLimits` absent. Lower limits are propagated rather
than reconstructed from undocumented defaults. Numerical configuration explicitly
sets time steps, voltage/current/LTE tolerances and iteration/reduction ceilings.
The profile ownership and consumption path is explicit:

| Profile | Owner consuming it | Lifetime and units |
|---|---|---|
| `maximumInputBytes` | Clock model loader | Cumulative exact source bytes for the admitted model |
| `maximumProjectionRecords` | Model and conductor projection | Source facts, geometry records, electrode faces and correspondence probes |
| `captureLimits`, or documented legacy record/probe mapping | Existing layout conductor capture | One flat actual candidate; independent hierarchy, decomposition and candidate-contact units |
| `maximumCellSpanDBU`, `extraction` | Existing PEX calculator | Same captured candidate, exact DBU conversion and mesh/operator budgets |
| `electrodes` | Existing PEX electrode builder | Explicit retained faces, finite contacts and electrical boundaries |
| Time horizon, step/refinement and crossing-agreement fields | Clock transient measurement | Explicit numerical/model policy for each measured root or branch |
| `transient` | Existing CoreSpice transient, composed by clock measurement | Accepted steps, solves, Newton work, saved scalars and work are subtracted from one request-owned allowance across candidates, edges, branches and refinements; matrix and breakpoint ceilings bound each transient run |

The selected actual-cell fixture retains an operational transient work ceiling
selected from the previous work surrogate using checked integer arithmetic. For
maximum matrix dimension `D`, square CSR has at most `D * D` entries. The passive
circuit creates at most `extraction.maximumNetworkElements +
electrodes.maximumContacts + maximumProjectionRecords + 1` devices: extracted R/C
elements, electrode resistors, terminal loads, and one explicit voltage source.
The previous per-iteration surrogate was `D^3 + 2 * NNZ + 2 * devices + 8 * D`;
it was not measured FLOPs. With the selected hard limits, the device bound was
8,110,001 and the iteration bound was 1,018,228,002. Adding the previous `20 * D`
LTE vector-work allowance before multiplying by the request-wide 1,000,000 Newton
ceiling selected work ceiling 1,018,248,002,000,000.

That ceiling remains unchanged as an operational limit. The corrected CoreSpice
Newton residual and refinement paths charge additional work; the previous formula
does not prove that the retained ceiling covers their worst case for all admitted
circuits or that the work guard cannot precede the Newton guard. The actual primary
and derived API and CLI fixture runs completed within this ceiling. CoreSpice's
typed matrix, CSR, device-binding and work admission remains authoritative. The
exact numerical configuration is retained in the model binding; tolerances, RC,
time window and other quotas remain unchanged. A serialized 120-second execution
bounds each validation attempt independently; successful CTS for other inputs is
not implied by this finite ceiling.

The selected actual-cell fixture owns a caller-supplied minimum timestep of
`1e-19` seconds as its operational resolution floor. Independent Decimal80
references reconstructed the full and half-step systems at this one candidate
floor from the retained zero-state R/C/PWL models with `gmin = 0` and unchanged
tolerances. Their normalized bootstrap LTE values are:

| Retained model dimension | Normalized bootstrap LTE at `1e-19` seconds |
|---|---:|
| 455 | 0.07659417864647895 |
| 847 | 0.03690267873598096 |

This reference establishes only the first step of those two observed models.
Equilibrated condition estimates and independently accumulated residuals accompany
the reference; they do not certify a componentwise forward-error bound. Every
other net, later timestep, refinement and the complete CTS flow still requires the
actual bounded integration run. The fixture may select this floor without changing
CoreSpice algorithms, production defaults, tolerance, RC, original source assets
or other quotas. The timing model is newly encoded with this numerical setting;
its artifact bytes, digest and request binding are new. Minimum-step failure and
timeout remain explicit failures.

The fixture owner checks the complete downstream profile against the same candidate
before claiming success. Raising one failed default does not establish that later
mesh, electrode or transient quotas are sufficient. Numerical tolerances, physical
mesh resolution and timing constraints are independent of resource ceilings; a
resource failure cannot silently change any of those model assumptions.

No-progress, minimum-step rejection, overflow and exhausted limits are typed
failures, not partial completed observations.

Refinement halves the maximum step within explicit minimum-step/refinement/work
limits. Recorded sink arrival/slew differences must meet the caller's crossing
agreement tolerance. This is numerical agreement, not a proof of absolute analytic
error. Independent representative fixtures report actual error separately.
Unsupported profiles, sources, units, corners, model ranges, shapes, terminal
conditions, unsatisfied constraints and missing crossings publish no successful
revision. Geometry/model convergence/constraint satisfaction are separate typed
observations. `claims.timing` and `claims.production` remain blocked for physical
signoff; model success does not grant foundry or tool qualification.

## Verification and Change Impact

| Invariant | Behavioral evidence owner |
|---|---|
| Real Liberty units/cap/threshold/arc semantics and no extrapolation | TimingEngine strict-characterization tests |
| Public PWL, passive RC waveform and bounded solve/cancellation | CoreSpice bounded-transient tests |
| RC material/mesh/cut/contact and exact electrical topology | Existing PEX component tests |
| Source DBU mesh span survives capture-grid refinement; span overflow rejects atomically | `CharacterizedNativeCTSTests` real projection and engine rejection tests |
| Native source-bound CTS composition | PhysicalDesignEngine ClockTreeSynthesis tests through actual API and CLI |
| Actual sink delay/slew/load/skew | Independent one-pole and two-section analytic fixtures, asymmetric Liberty tables and fanout loads |
| Missing/unknown/unsupported input and constraint failure | Actual engine typed blocked result and empty artifacts |
| Candidate and numerical limits/cancel/atomic publication | CTS tests preserving original snapshot and store state |
| JSON/DEF truth and resume boundary | Exact persisted bytes and independent standard geometry/connectivity comparison |

Reuse `.build/b5-routing`; do not introduce a new cold cache. Verify exact lower
dependency closure before compilation. Run representative cost/error checks,
focused integration, one comprehensive review plus targeted finding recheck, then
affected package verification once. Host caller/dependency adoption belongs to
Xcircuite's owner; it consumes immutable verified commits, never this working tree.

### Geometric path metadata

The characterized profile does not claim centerline path lengths through multi-area PORTs. `ClockTree.shortestPathLengthDBU` and `longestPathLengthDBU` are optional and absent in this profile. Actual routed conductor geometry and mesh identity are retained; arrival/slew/skew come exclusively from saved transient voltages. Legacy geometry smoke measurements do not become characterized timing evidence.

### Source corner and asset role admission

The request selects a PDK corner (`cornerID`) and an explicit electrical RC corner (`rcCornerID`); the latter must equal the selected PDK corner's declared `rcCorner`. Liberty and RC asset IDs must belong to that PDK corner and have `.liberty` and `.extraction` roles respectively. Electrical RC parameters are explicit, retained, and checked by the PEX owner. A PDK corner name is not silently reused as an RC corner name.

Artifact publication starts only after numerical and standard export admission and a final cancellation check. A completed result requires all written artifact bytes to be read back and verified. Store I/O failure cannot become completion; unreferenced partial run files from a multi-write I/O failure carry no successful result/manifest authority. The CTS candidate itself stays invocation-local until numerical constraints succeed.

Primary-clock and actual-cell CTS equivalence regressions are owned by
`PhysicalLogicHandoffTests/NativeCTSLogicEquivalenceTests.swift`: checked source
synthesis, actual Native CTS stage, retained JSON/DEF, reconstructed candidate
actual functions and independent RUP recheck. Selected Sky130 source facts and
analytical fixture RC remain explicitly unqualified; these tests do not certify
full raw PDK acceptance, foundry accuracy, PEX/STA/DRC/LVS closure or release.

### Interconnect material boundary

Clock RC projection includes typed routing metal and cut layers. Typed `.well`
MASTERSLICE regions retain their complete source and snapshot identity but are not
interconnect metal; no well resistivity or substrate dynamics are fabricated.
Selected terminals/electrodes on excluded well layers fail explicitly. All routing
metal, supply-rail metal, actual PORT pieces, routes and fixed via geometry remain
in the interconnect capture. OBS remains the routing owner's obstruction contract,
not fabricated conductive material. Substrate/well dynamics and full process
qualification are outside this prescribed-PWL interconnect profile.

## CTS Candidate Generation Profile

The characterized CTS model declares exact exposed electrode faces. Its current
bounded candidate generator uses preferred-axis track routing and explicitly
disables terminal-track jog generation. Ordinary signal routing retains its
terminal-only jog domain; physical admission of qualified retained orthogonal
metal is unchanged. This is a candidate-generation choice, not a LEF DIRECTION
prohibition. Every CTS candidate still passes the same complete geometry, exposed
face, extraction, transient and source-bound proof gates.

Source-face-aware CTS terminal-jog generation is unsupported. A new jog can
physically internalize a declared face even when ordinary source spacing and
connectivity are valid: the observed cell-1/CLK minX x8370/y3820..4220 was covered
for 45 DBU by the li1 jog (8510,3780)..(8050,3780), width170/caps85. The lower
electrode builder correctly rejects the missing exposed interval. Supporting
that additional CTS domain requires explicit face-aware candidate admission;
there is no fallback that ignores or moves a source electrode. The working
preferred-axis profile is verified by fresh actual-source CTS publication and
its existing numerical gates, not generalized face-aware CTS qualification.

RoutingTerminalJogTests distinguishes the same fixture's ordinary jog-capable
domain from preferred-only refusal. NativeCTSLogicEquivalenceTests verifies fresh
actual CTS face admission, exact generated-edge uniqueness and functional proof.
