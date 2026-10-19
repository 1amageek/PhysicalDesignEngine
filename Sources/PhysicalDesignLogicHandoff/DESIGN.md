# PhysicalDesignLogicHandoff

## Purpose and Scope
Parent: [Package](../../DESIGN.md). Child: [CheckedCandidatePersistence](CheckedCandidatePersistence/DESIGN.md). Host-only actual-cell logical
connectivity admission, additive ECO functional admission, and an explicit
same-candidate normal-power STA binding for a supplied physical snapshot.

## Responsibilities and Boundaries
The baseline exact-connectivity operation checks a total instance/port correspondence,
exact master and physical pin names, pin directions, and a bijection of net
connectivity against checked synthesis.
Return immutable checked owners. The additive ECO operation reconstructs a candidate
actual-cell graph and composes the existing equivalence checker and independent
RUP rechecker. The original exact-connectivity operation is unchanged.
Geometry, placement, LEF/PDK view admission, numerical timing analysis,
DRC/LVS and release remain existing physical/domain owners. No dimensions,
positions, pin shapes or cell function are inferred or fabricated.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Physical boundary | Host handoff | Logical check only |
| [CheckedCandidatePersistence](CheckedCandidatePersistence/DESIGN.md) | child | Atomic checked candidate export/reload | Exact standard source/proof artifact handoff | Raw references are not verified owners |
| [PhysicalDesignCore](../PhysicalDesignCore/DESIGN.md) | depends on | PhysicalDesignSnapshot | Supplied physical state | Geometry requires independent admission |
| [Runtime](../../../LogicEngine/Sources/LogicEngineRuntime/DESIGN.md) | depends on | LogicVerifiedSynthesis | Checked baseline actual cells | Legacy artifacts cannot construct this owner |
| [LogicProof](../../../LogicEngine/Sources/LogicProof/DESIGN.md) | depends on | LogicEquivalenceProblem, check, independent RUP recheck | Candidate functional proof | Inconclusive never grants acceptance; proof owners remain exact |
| [STA PreparedExecution](../../../TimingEngine/Sources/STAEngine/PreparedExecution/DESIGN.md) | depends on | PreparedSTAExecution checked design binding, STASourceEvidenceValidating | Exact candidate and saved strict timing evidence | Input-reference digests do not substitute for checked parsed connectivity |

## Architecture
```text
source -> Runtime checked reload -> actual-cell graph + functional proof
physical snapshot + explicit canonical IDs -> logical connectivity checker
  -> immutable checked physical/logical handoff -> existing physical stages
```

## Contracts and Invariants
Both operations require all actual instances and port bits to correspond exactly
once. Every physical pin belongs to exactly one net and matches a real cell pin
or supplied port bit. Unused physical pins and undeclared identities fail.
The baseline exact-connectivity operation additionally requires the original master
and net bijection: a baseline canonical net cannot split or join another net.
ECO admission permits explicit changed masters and topology only through the
actual-cell functional proof contract below.
Master/pin aliases require an explicit future view contract and are currently
rejected. Handoff requires the current checked Runtime request/receipt contracts
and physicalCells policy. The portable realization validator rejects
specified startup not realized by the actual cell and logical constant drivers.
Logic realizes exact inputless tie-cell instances before its proof and receipt;
Physical never adds an unproved logical instance or substitutes a power alias.
Two-state proof does not become geometry
or four-state evidence. The returned owner cannot be decoded or publicly created.

## State, Ownership, and Lifecycle
Checking tables are call-local; inputs and checked outputs retain immutable value
owners. The [persistence child](CheckedCandidatePersistence/DESIGN.md#state-ownership-and-lifecycle)
owns its separate awaited artifact lifecycle.

## Failure, Concurrency, and Constraints
Typed mismatch, unsupported and resource-limit failures. Caller-selected positive
limits bound instance, pin and net counts before table allocation. The baseline
checker performs no search or implicit repair. ECO admission composes bounded
existing SAT search and independent proof rechecking using the same kernel budget.
Neither operation repairs a candidate. Geometry fields are retained but not
traversed or certified.

## Verification and Change Impact
PhysicalLogicHandoffTests checks source/save/reload followed by exact physical
connectivity admission; wrong master, pin rewiring, missing correspondence and
resource exhaustion fail. Runtime owns functional proof and physical owners own
source-bound geometry/view validation. This module adds no dependency to Core.

## Exact LogicEngine Retirement Adoption

Package.swift adopts LogicEngine `57615d4`, which retires metadata execution APIs
and their discovery fields. This module consumes the unchanged current Runtime
checked-synthesis owner; the fixture exercises the unchanged Core artifact store.
No retired graph DTO or engine participates in the selected path. Physical production and test Swift sources
remain unchanged from `2af4aa9`.

The exact normal dependency graph is exercised through the existing
`checkedSourceNetlistAdmitsExactPhysicalConnectivityAndRejectsMutations` test:
source/Liberty synthesis, saved receipt verification, eight actual AND instances
and exact physical connectivity admission, followed by typed master, pin, wiring,
identity and resource refusals. [Current consuming evidence](../../../.verification/runs/s3-stageIII-20261013-2e1f3af7/cleanup-physical/completion.json)
owns this macOS CPU compatibility scope. Existing geometry, DRC and portable
kernel proofs retain their original unchanged premises; this adoption does not
claim new geometry behavior or process/release qualification.

## ECO Candidate Functional Admission

`PhysicalLogicECOChecking.check` consumes checked synthesis, a caller-owned candidate
snapshot, explicit `PhysicalLogicECOCorrespondence`, count limits and one shared
`inout LogicKernelContext`. It performs no artifact I/O or physical mutation.

```text
candidate snapshot + total canonical IDs + baseline compiled Liberty library
    -> actual MappedGateBuilder -> physicalCells realization validation
    -> original bit / candidate mapped LogicEquivalenceProblem
    -> NativeLogicEquivalenceChecker -> independent RUP recheck if equivalent
    -> immutable candidate / correspondence / mapped / problem / verdict owner
```

| Correspondence | Admission |
|---|---|
| Canonical instance and net IDs to physical IDs | Total and unique; no generated identities; graph builder checks cross-domain collisions |
| Original bit-port ID to ordered physical pins | Total over all bits; exact direction; every top pin used once |
| Original bit-state ID to candidate physical instance | Total bijection over stateful cells; original state identity and initial range retained |

Every candidate pin belongs to exactly one declared net, has the exact actual-cell
name and direction, and is consumed exactly once. Every net has exactly one real
output or top input driver. Unknown masters, unused pins/nets, supply aliases,
undriven or multiply driven nets and malformed membership are rejected. Constants
require actual inputless tie cells. No function is inferred from master names or
pin counts. The baseline compiled library is the sole functional authority.
Candidate port order is the original bit graph order; candidate state order is
explicitly paired to original state IDs, independent of instance declaration order.
Clock, reset, enable and state function semantics are checked by the existing
actual-cell equivalence implementation. No startup value is invented.

`PhysicalLogicECOAssessment` has no public initializer. It retains the exact checked
baseline synthesis, snapshot, correspondence, graph, problem and existing
`LogicEquivalenceVerdict`. Equivalent
contains independently rechecked proof bound to that problem; different contains
the existing checker independently replayed concrete witness. A proof-stage
interruption remains inconclusive. Projection/problem construction failures throw
with their typed kernel cause and produce no assessment. No optional or fabricated
problem is returned. `requireBinding(to:)` refuses a different candidate snapshot.

Count limits precede projection workspace allocation; the shared kernel context
accounts for bounded projection tables, correspondence arrays, graph construction,
search and independent rechecking without resetting budgets. Projection scratch
uses dense arrays with stride-derived payload reservations and charged source-boundary
linear lookups and retains no shared mutable state.
This host-only operation adds no Native/WASM/Embedded concurrency claim.

`PhysicalLogicECOTests` owns source-to-checked-synthesis-to-candidate regressions:
identity replacement/buffer equivalence, wrong-function replacement and INV insertion
concrete differences, exact candidate/problem binding, total identity/pin/state
refusals, FF/latch control semantics and resource/cancellation failures. Existing
`PhysicalLogicHandoffTests` continues to own unchanged baseline admission. This
lower operation does not certify geometry, characterized timing, PEX, DRC, LVS,
process qualification, release or the final same-candidate ECO feedback loop.

## Native CTS Candidate Consumption

The existing ECO checker also consumes actual Native CTS outputs. Original checked
RTL, actual library functions, canonical state/port identities and total candidate
correspondence remain authoritative. Per-FF physical buffer branches are retained
and the lower derived clock lineage/proof contracts normalize only their logical
clock action; simulation still evaluates physical carriers and local edges.

```text
checked RTL / actual Liberty / explicit TT process scope -> exact initial physical correspondence
    -> Native CTS stage with source geometry and explicit PWL/RC profile
    -> persisted candidate -> existing ECO projection and equivalence checker
    -> independent RUP recheck / exact candidate binding
    -> same saved candidate / source-coefficient pre-route star RC
    -> strict TT STA / saved result replay / explicit normal-power STA binding
```

`NativeCTSLogicEquivalenceTests` owns primary-clock and derived-inversion CTS,
source-bound buffer functions, wrong clock roots/functions/edges, saved/reloaded
candidate binding and rejection evidence. Both actual API and bound built CLI run
the primary and derived cases. The primary PORT-use preservation check applies only
to the primary root; a derived internal-cell root has no top-level PORT.
The retained CLI producer has separate primary and derived test wrappers over the
same complete validation body. Each run uses an explicit 180-second child deadline
and a 240-second outer test profile; prior two-case CTS API/CLI runs took 74.855
and 69.213 seconds respectively. No kernel work or numerical allowance changes.
The CLI candidate independently rejects duplicate exact qualified conductor
footprints on the same net/layer before downstream use. This assertion observes
published geometry rather than repeating the generated-route normalization owner.

A fresh `native-cts-cli-9` cohort retains each actual-cts request/result and exact
JSON/DEF artifacts. Its two saved candidates feed four fresh source-adoption
subjects, new-manifest checked Logic baselines, then four independent routing and
RUP/save/reload validations. Earlier CTS/routing/PEX evidence remains historical;
changed conductor inventories require fresh downstream extraction and timing.
No hand-authored clock tree substitutes
for the Native producer. Selected source profiles disclose all omitted process
rules and fixture RC assumptions; functional proof is separate from physical
qualification and same-candidate PEX/STA/DRC/LVS gates.

The selected fixture's PDK device inventory is a projection of the checked actual
Liberty library's standard-cell names and validated functional pin tables. Terminal
ordinals preserve those tables, directions preserve actual input/output semantics,
and an FF control pin is marked as clock from the validated state definition.
The same device IDs bind the existing LEF and Liberty views. This inventory does
not declare transistor models, SPICE subcircuits, extraction recognition or PG
terminal semantics; actual PG metal remains owned by the retained physical source.

The request-seven baseline registers one exact Liberty `ArtifactReference` and one
TT manifest before synthesis and retains an explicit `LogicOperatingProcessScope`
without requesting a baseline STA measurement. The Physical and Logic consumers
share those same references, rather than re-registering equal bytes under another
descriptor.
The manifest explicitly binds its Liberty asset and view to `tt`, with observed
`tt_025C_1v80` source conditions. Every selected cell, including later CTS buffers,
has caller-declared VPWR/VPB = one and VGND/VNB = zero, with the exact retained
primary-power/ground and nwell/pwell source PG types. These conditional functional
premises do not measure physical supply delivery.

After each actual API/CLI candidate is saved and read back, the test independently
builds its Physical-name signal graph and invokes the existing
[explicit STA binding contract](#explicit-normal-power-sta-binding). The existing
LegalPlacement source-coefficient projection generates a pre-route star network
from that exact snapshot and the retained li1 sheet-resistance/area/edge-capacitance
facts. Its technology asset, TT corner, profile, snapshot digest and finite budget
are retained. A separately identified caller external load at each output PORT
is equal to the retained dfxtp D-pin capacitance; it is an explicit test load,
not a measurement of an external circuit or a second library pin load.
Canonical SPEF preserves terminal identities. Actual propagated primary clocks,
all five check kinds, all four explicit PG conditions, strict source evidence and
its bounded replay bind the saved STA result to the already-proved candidate.
The original CTS analytical extraction model, numerical profile and geometry are
unchanged. The additive STA network is source-coefficient **pre-route** prediction;
it is not routed extraction, process qualification or postroute timing closure.

The fixture's caller spacing floor is 140 DBU. The router applies the maximum of
that caller floor and each retained source rule, preserving li1's 170 DBU and
met1's 140 DBU source spacing. The former uniform caller floors of 170 and 190 DBU
cannot provide legal access through the actual macro PORT/OBS corridor; their raw
refusal receipts are retained. The 190 DBU floor is also an explicit refusal profile.
Distinct manual top-port rectangles use one flat source-port ordinal with a 500 DBU
pitch and 200 DBU height. The primary clock rectangle is centered at the retained
li1 track x = 16790 DBU, and every other top PORT is centered at the retained li1
track x = 17710 DBU. The full source-width wire cap must fit inside every actual
200 DBU PORT, checked against the retained track table and source WIDTH before
CTS. The primary source electrode faces derive from that same retained rectangle.
The former 50 DBU adjacent-port gap remains an explicit refusal regression.
These placements and caller bounds do not change source tracks, WIDTH or spacing
laws, or waive existing-material checks.

The current request selects `sourceRoutingWidthPolicy: .sourceDefault`: generated
ordinary CTS wires use each actual layer's declared WIDTH, li1 170 DBU and met1
140 DBU. The scalar 170 remains present for the explicit `.uniform` refusal profile;
it never replaces a source default. The legacy clock-model-v2 test still uses the
current request schema and width policy, preserving the model's raw version and
digest independently. Saved JSON segment widths and shared DEF-reader footprints
are checked against the same source-default geometry. This verifies standard
output/readback, not Native DEF intake or process qualification.

## Explicit Normal-Power STA Binding

The additive synchronous `PhysicalLogicECOAssessment.requirePreparedSTABinding`
operation checks one already-assessed candidate against one prepared STA execution
before any response is required. The asynchronous `requireSTABinding` operation
composes that same admission with strict source-backed result validation. It does not change the functional-only meaning of
`PhysicalLogicECOChecking.check`, `requireBinding(to:)`, or an equivalence verdict.
It introduces no executor, artifact store, qualification owner, or publicly
constructible checked receipt.

```text
retained checked baseline + equivalent ECO assessment + total correspondence
    -> Logic-owned policy expansion over every candidate mapped instance
    -> physical-name signal TimingDesign and exact per-instance supply conditions
    -> Prepared-owned check against the retained parsed STA design and conditions
    -> requirePreparedSTABinding succeeds without a response
        -> Timing-owned initial source contexts, when available in the public dependency
        -> STA execution and strict saved-result validation against the same owner
```

| Owner | Authority consumed by the join |
|---|---|
| Logic Runtime | Checked baseline source, explicit source-cell supply policy, candidate-wide expansion including newly inserted cells, and lower normal-power validation |
| This module | Exact assessed snapshot, total canonical-to-physical correspondence, physical names, and composition of the checked lower operations |
| STA PreparedExecution | Actual retained parsed connectivity, selected corners/libraries, effective conditions, and strict result/source reconstruction |
| Timing Core | Source Boolean, state, and PG role interpretation; Physical never evaluates or reproduces these laws |

The initial contract requires exact `ArtifactReference` equality between the
baseline mapping library and each selected STA corner library. Equal cell names,
paths, or functional claims do not establish interchangeability of distinct
library artifacts. The baseline must retain an explicit `LogicOperatingProcessScope`; nil
source-only functional scope is refused rather than promoted to a timing corner.
The exact process manifest reference, process/version, corner set, and selected
source characterization bindings agree with that scope. Its declared libraries
are the same exact mapping source. This conditional functional premise is
independent of optional baseline timing measurement: an explicit scope with no
baseline SDC/STA run can enter the join. Logic owns scope construction, validation,
derivation from legacy timing arguments, and agreement when both are supplied.
Physical consumes the checked scope without deriving or inventing one. SDC bytes
may differ between measured graphs because their interchange names differ; the
functional proof continues to quantify over all data and state values.
The original explicit Logic policy is expanded over
`assessment.mapped`, rather than copying the baseline receipt's instance list.
Every expansion is mapped through the checked canonical instance correspondence;
missing, duplicate, foreign, or extra instance/cell/corner/PG identities fail.
Exact source PG roles and binary values remain caller-declared conditions, not
measured power or inferred rails.

The expected signal design retains physical instance, net, pin, and top-port
identities, connectivity, constants, and source cell identities. Logic Runtime's
anonymous timing export names are not used. STA's public checked binding operation
compares against its actual retained parsed design; request digests and caller
assertions are insufficient. The saved STA result must pass the existing
`STASourceEvidenceValidating` operation against that same prepared execution.
Only an equivalent, independently rechecked ECO verdict can enter this join.
The snapshot has no inline timing capacitance or port clock metadata, so its
expected signal baseline explicitly has zero inline capacitance and nil port
clock metadata; separate SPEF and SDC inputs remain STA-owned. The Prepared
comparison preserves these fields, ignores declaration order, and treats a nil
port net and an explicit same-name net as equivalent.

The synchronous operation is
`requirePreparedSTABinding(to:limits:context:) throws(PhysicalLogicSTABindingError)`.
It returns no new receipt and grants only the existing exact candidate, process,
library, corner, normal-power and parsed-connectivity join. It neither generates
a source family nor certifies a completed response. A caller may subsequently
use the same prepared owner through Timing's public initial-context protocol;
that lower API requires a published exact dependency revision before adoption.
Only an explicitly tagged primary-port entry is a candidate independent physical
source. A prescribed cell output remains a Timing boundary assumption and cannot
be promoted to an independent physical source by this operation. Physical does
not construct voltage laws, time or rail mappings, source jets or causal proofs.

The completed-result operation is
`requireSTABinding(to:result:validator:limits:context:isolation:) async throws(PhysicalLogicSTABindingError)`.
It first calls the synchronous admission, which consumes checked policy expansion
from `LogicVerifiedSynthesis` and `PreparedSTAExecution.requireDesignBinding(to:)`,
then invokes the supplied
`STASourceEvidenceValidating` protocol requirement. Its default actor isolation
is inherited from the caller so the noncopyable kernel context does not transfer
to another executor. Topology scratch is destroyed and released before awaiting
the evidence validator; kernel cancellation checks bracket that await.

The existing signal-only functional pin inventory remains the supported snapshot
contract. Extra physical PG pins are not silently removed or interpreted. Source
supply assumptions and this join do not establish PG metal connectivity, voltage,
IR/EM, process qualification, whole-path timing closure, or production eligibility.
Those remain separate physical/electrical signoff responsibilities.

Count and byte reservations precede projection scratch allocation. The Physical
join owns one topology-scratch reservation and releases that exact receipt on
normal and throwing exits, before awaiting source-evidence validation. The same
caller context also funds Logic's public candidate-condition qualifier. That
lower operation returns checked immutable values without a caller release API;
its existing conservative run-context storage charges are not Physical scratch
and are not a live-allocation/RSS measurement. This join does not promise a zero
total invocation storage counter or change the lower accounting semantics.

The focused accounting test invokes the exact public qualifier independently
with the same baseline, mapped candidate, inferred corners and limits on a fresh
reference context. Across two calls on each context, Physical's retained-storage
delta must equal the lower-only delta. Physical must also incur exactly one extra
storage reservation and positive additional allocation bytes per call. The
retained-delta check detects a missing scratch release; reservation/allocation
checks detect removal of the scratch admission itself. Cumulative work must grow.
Existing count/work/storage/cancellation refusal tests remain required. The
original zero-total expectation failure is retained as the red evidence; this
correction distinguishes component-owned refund from lower run charges without
weakening numerical, source, proof, STA or artifact assertions.

Identity traversals and policy expansion charge the existing shared kernel
work/storage budget without resetting it; cancellation is checked at charged
boundaries. STA
validation uses its retained execution limits and typed failures. The operation's
dedicated `PhysicalLogicSTABindingError` preserves functional, kernel, Logic
operating-condition, Prepared-design, and STA evidence causes without changing the
existing equatable functional error. No mutable
shared state or asynchronous callback is retained by the assessment. Lower API
formal types are coordinated with the owning Runtime and PreparedExecution
implementations before source composition is implemented.

`NormalPowerSTABindingTests` owns the dedicated source-to-checked-baseline-to-ECO-
candidate-to-STA binding regressions. Prepared admission is exercised before any
execution or result construction, with cumulative work and released projection
storage on the same caller context; completed decoding/replay and foreign-result
refusals remain separately exercised. A valid candidate with added cells must
receive conditions by checked policy expansion. Explicit process scope without a
baseline STA measurement is accepted; absent scope remains functional-only.
Wrong candidate connectivity,
physical identity, source artifact, corner, PG role/value, missing added-cell
conditions, inconclusive functional verdict, and another execution's saved result
must refuse. Existing Native CTS fixtures remain unchanged until the task owner
schedules their higher-level integration.

## Checked Candidate Artifact Export and Reload

The [CheckedCandidatePersistence child](CheckedCandidatePersistence/DESIGN.md)
owns the additive publication and checked reload contract. Detailed-routing consumers
use its exact saved candidate source-netlist and certificate references; functional
assessment and normal-power STA binding remain this module's existing contracts.
