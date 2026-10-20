# Whole Candidate Flow

## Purpose and Scope

Parent: [PhysicalDesignLogicHandoff](../DESIGN.md). No children. This is a
implementation contract for RL1.7.2.1.7.4.3. The implementation is not qualified
until its public-graph focused execution and scoped review complete.

Own the actual same-candidate electrical construction and a sealed composition of
checked Timing source families with the finite conditional Native flow. Preserve
the entire extracted physical circuit, including endogenous inverter outputs.
A primary-input-only join cannot be reported as a complete Timing/Native seal.
This operation is not a new simulation solver, orchestration facade, source-family
factory, model implementation or caller-callback certificate.

## Responsibilities and Boundaries

| Owner | Responsibility used here |
|---|---|
| Existing Handoff assessment and persistence | Exact physical candidate, total logical correspondence, actual-cell functional proof, checked saved/reloaded candidate |
| Existing Handoff prepared-STA join | Exact signal graph, process/library/corner and source Bool-PG premises against the actual retained Prepared STA owner |
| This child | Complete original SPICE/PEX/PG/body-to-candidate association; actual controlled whole Native preparation; checked numeric rail/gauge/time mapping; complete family and endogenous-observation join; sealed immutable result and failure ownership |
| Timing | Checked family production, source/load/arc/threshold/history semantics and same-family joint initial/window projections |
| PEX | SPEF decoding, canonical parasitic semantics, standard SPICE writer/composer; extraction qualification remains separate |
| Core | Actual model binding, source normalization, controlled preparation, conditional flow, voltage/rate observations, numerical proofs and helper lifecycle |

Caller source/model profiles, numerical boxes, gauges and artifact locations are
untrusted inputs. Their values become retained conditions only after checking
against actual source bytes and lower owned values. Bool supply labels, a path,
a cell name, a source count or a raw receipt cannot substitute for that check.

## Related Designs

| Design | Relationship | Contract Used | Cautions |
|---|---|---|---|
| [Handoff](../DESIGN.md) | parent | Existing assessment and prepared-STA admission | Signal/Bool-PG binding does not prove full SPICE, numeric rails or setup |
| [CheckedCandidatePersistence](../CheckedCandidatePersistence/DESIGN.md) | sibling | Actual candidate reload and independently rechecked proof | No raw manifest-to-owner promotion |
| [PhysicalDesignCore](../../PhysicalDesignCore/DESIGN.md) | depends on | Exact supplied snapshot/process state | Geometry/PG delivery is not inferred from logical normal-power conditions |
| [Timing SourceFamilies](../../../../TimingEngine/Sources/STAEngine/NativeExecution/ConservativeCoupling/SourceFamilies/DESIGN.md) | depends on | Checked context and private-init jointSlice | Required published revision is `d6d0bec0ee5b97a25687ad0db02e127b6d3a9df0`; older local/public pins need explicit adoption |
| [Timing PreparedExecution](../../../../TimingEngine/Sources/STAEngine/PreparedExecution/DESIGN.md) | depends on | Revalidated source context, exact process/observed characterization | Selected numeric voltage/temperature must be present; no inferred default |
| [Core Native Flow](../../../../CoreSpice/Sources/CoreSpice/NativeExecution/PrescribedVoltageFlow/DESIGN.md) | depends on | Actual private-init conditional result and borrowed complete scope | Published Core revision `40eefa8efe9960def7d7151298e96f898cbebab2`; no family nonemptiness or Physical seal supplied by Core |
| [Core NativeExecution](../../../../CoreSpice/Sources/CoreSpice/NativeExecution/DESIGN.md) | depends on | Direct NativeConstitutiveCircuitPreparing and actual inspection | Use actual exclusive owner, not a caller-built record or arbitrary proof callback |
| [PEX](../../../../PEXEngine/DESIGN.md) | depends on | Public standard-format production and parsing | Exact binary64 passive roundtrip must be verified on the adopted implementation |

These lower documents remain canonical for their algorithms, budgets and
lifecycle. This child owns only the additional cross-domain joins below.

## Architecture

```text
checked ECO candidate + same actual Prepared STA
    -> existing requirePreparedSTABinding
    -> exact candidate / original cell SPICE / model/include / numeric PG / SPEF
    -> complete standard SPICE composition + cold passive equality
    -> actual SPICE catalog/parser/lowering + external MOS bindings
    -> direct controlled NativeConstitutiveCircuitPreparing
    -> actual Native conditional Flow -> Core-owned voltage observations
    -> borrowed observations.flow.withScope

same Prepared STA -> NativeSTAEngine checked contexts -> actual jointSlice
    -> whole-family initial/window/AE-slope inclusion for independent inputs
actual endogenous Native voltage/rates + exact endpoint/load/arc mapping
    -> discharge every demanded internal-output premise
both paths + exact source/rail/time/model/candidate joins
    -> private-init immutable whole seal, or typed refusal with unclosed premise
```

The public operation belongs on the existing assessed-candidate boundary;
its implementation resides in this child. It must produce the actual Native
owner internally and invoke the concrete qualified lower operations. No new
wrapper module, public proof callback, caller-created checked scope, decode-to-seal
constructor or generic availability facade is introduced. Its frozen implementation interface is defined below. Lower declarations retain
their original owning contracts.

## Contracts and Invariants

### Actual complete circuit producer

First invoke the existing assessed-candidate/prepared-STA check. Bind immutable
candidate bytes/reference, checked correspondence and all source artifacts using
content identities; availability and execution paths remain separate.

Reuse the existing actual witness's source construction responsibilities, not its
JSON success flag: match every instance/master and top port to original cell
subcircuit port order; retain all original MOS leaves and their full D/G/S/B
mapping, original include/model declaration identities, scalar/RNG provenance,
geometry scale/bin selection and explicit/default/Given assignments. Retain all
PG and body connections. Do not replace an internal signal with a voltage source,
flatten away an unobserved leaf, add a dummy device or silently resolve a naming
collision. Root-level observation terminals are names, not extra physical devices.

The retained actual fixture has four cells, five top ports, 16 per-instance
PG/body premises, five original SPICE source assets, 56 MOS leaves (28 N/28 P),
15 distinct physical signal pins and 21,437 passives. These are regression facts
of that exact candidate, not a hard-coded general circuit schema. The passive
inventory is 10,580 R, 9,296 ground C and 1,561 coupling C; Core's lowered capacitor
count is therefore 10,857. Preserve kind, both canonical endpoints, binary64 value
bits and multiplicity through public writer, cold parser, whole composition and
actual lowering. Counts alone cannot prove equality.

Use the actual `SPICESimulationPreparer` checked-source catalog/include routes and
external MOS preparation results, then apply only the declared ideal-connection transformation below and pass the
checked derived immutable circuit and same operating conditions to
`NativeConstitutiveCircuitPreparing`. Retain the source
input/configuration identities and compare them to actual Native `plan.ir`,
instance setup receipts, raw/active/global projection and Flow scope. The
per-model setup witness is not a prepared whole circuit. No SPICE model physics,
MOS schema or derivative reconstruction is implemented in Physical.

The historical reusable source is Core's
`.verification/compensated-norm-followup-20261019/provider/whole-cone/pvt-r2/composition-r4/`:
`WholeConeWitness.swift` SHA `cb79ada6941cb16499b5943d098eae450cabb9c27f85788b24780929cc812237`
and `PEXWholeConeComposer.swift` SHA
`4b275e0091a6e5a7db0af343504e8555508b73cc9ae5c9e158a99f0dd6a20586`.
The corresponding `composition-r9/qualification.json` SHA
`719a4489df131aa72aee453e4d2b5b0ea1e48d639af65bf62d58c100977ce097`
proves its recorded source preparation/per-model setup/passive paths only. It
neither constructs a whole Native Flow owner nor grants the future public PEX
implementation the historical binary's properties. Never open captured process
environment/compile plans as source authority.

### Numeric PG, rails, gauge and operating conditions

Construct an immutable numeric association only from actual checked source and
prepared values. For each functional PG premise, preserve instance/pin/PG role,
original subcircuit position, body/MOS terminal and actual Native node. Check the
actual bound independent source's signed terminals/branch and represented rail
voltage. Bind the explicitly selected gauge/reference node; no common-mode shift,
implicit global ground or ideal delivery is inferred from Bool one/zero labels.

Each normalized input law must use this same checked zero/one rail pair and actual
source orientation. Its represented voltage difference must agree with the
selected observed Liberty characterization voltage under an explicit exact/unit
policy; no tolerance or Celsius/Kelvin offset is guessed. Missing observed numeric
conditions, ambiguous multiple rails or an unrepresentable/unsupported gauge
refuse until an owning policy is supplied. The fixture's original ground/VPWR and
VPB/VNB ties are retained; future multi-rail support needs equally total source
association, not a guessed nominal rail.

Match the exact process manifest/version, corner, library and condition group
already checked by Handoff, plus actual ambient Kelvin/Celsius conversion,
simulation nominal temperature, model TNOM, provider/compiler/model/profile,
model/instance parameters and Given flags from the source preparation. Ambient,
caller nominal and model TNOM are distinct. Historical TT 25 C / 1.80 V, SS 100 C /
1.60 V and FF -40 C / 1.95 V inputs do not make nominal 27 C equal model TNOM 30 C.
Each selected corner is a separate exact operation; one cannot substitute another
corner's setup or flow. This remains conditional on the explicit actual electrical
supply model, not measured IR/EM or foundry qualification.

### Explicit execution-corner label profile

Before PEX lowering, require `request.pexCorner.value` to equal the exact
`cornerID` of the source context revalidated against the actual `preparedSTA`.
Use that same label in the lower operation. This checks association with one
selected execution; equality of caller-visible labels does not attest an
extraction, foundry, or physical PVT corner. The parasitic artifact authority is
still the exact retained `preparedSTA.request.parasitics.reference` and captured
bytes. Full per-corner extraction provenance remains an independent parent gap.
The historical nominal label is not a mandatory label for future operations.
A wrong-label regression must identify this execution-association refusal rather
than claim the source SPEF supplied a trusted corner declaration.

### Same Timing family and exact time

Obtain checked contexts from the concrete `NativeSTAEngine` for the SAME actual
Prepared STA owner, or revalidate a retained record with
`validateInitialSourceContext(_:against:)` before requesting its jointSlice.
A decoded record, independent jet, separately constructed point family or arbitrary
protocol callback is not authority. Match exact scenario, execution/configuration,
library, thresholds, source endpoint/owner net, origin, history generation,
source arcs and load identities. Preserve every demanded source entry exactly once.
Retain the common context/history relationships; outer interval projections do
not make every Cartesian tuple realizable or independent.

Obtain `jointSlice(sourceAt:initialTime:over:)` from that checked context. Its
Double SI time hull must contain the exact represented Native initial time and
entire actual Native window, including outward terminal expansion from t0+h.
Compare normalized DD points directly against binary64 hull endpoints, and
recheck the actual retained Native endpoint context after Flow construction. The
endpoint expansion is retained whenever the Core enclosure has nonzero radius;
projecting a positive-low initial point to an unnecessarily wider Double hull
must not replace exact point containment. No high-only conversion, ps/ns/seconds mismatch,
clock-phase translation or truncated negative history is accepted. Retain both
the actual DD Native times and actual Timing hulls in the checked result.

For each actual independent PRIMARY PORT input, require the entire Timing
`initialValue` within Native `initialNormalized`, entire `windowValue` within
Native `normalized`, and entire `almostEverywhereSlope` within Native's original
SI `normalizedDerivativePerSecond`. These are inclusions, not overlap, selected
member existence or comparison of internal normalized-time slope slots. The exact
endpoint/candidate/net/rail/gauge association is required in addition to the
numerical comparison. Core internally owns any slope timeScale conversion.

A genuine unrestricted Timing family contains the constant member U=0.5,
dU/dt=0. A conditional Native result with point U=0.5 and SI derivative 1 over
positive h cannot cover that family and MUST be refused. A fabricated point
Timing factory cannot be used to test this requirement. A second regression with
Native's value box wide enough to contain Timing but derivative excluding zero
must isolate the slope check rather than accidentally pass through another refusal.

### Endogenous internal outputs are mandatory obligations

Timing's `.prescribedCellOutput` is a boundary assumption, not an independent
physical source. Keep both actual inverter circuits and their output nodes
endogenous in the full extracted Native circuit. Never satisfy this entry by
injecting a V source, removing a cell, choosing a convenient source member or
omitting the entry from the seal.

An internal entry retains exact endpoint/owner net, source arc identities,
`prescribedBoundaryLoad` and load-model identity, rise/fall slew domains,
thresholds, and its currently unrestricted history. To discharge it requires
Core-owned voltage observations at the initial slice and throughout the slab,
plus SI almost-everywhere voltage-rate enclosures on the SAME actual Flow owner.
Normalize outward against the checked numeric rail pair and bind the actual
original coordinate and load/arc/corner/time/source scope. The Native response
must be contained in every applicable retained Timing boundary premise. This is
a response-membership obligation, distinct from covering every independent
Timing input family; interval overlap proves neither direction.

The qualified Core-owned
[same-flow voltage observation contract](../../../../CoreSpice/Sources/CoreSpice/NativeExecution/PrescribedVoltageFlow/DESIGN.md#proposed-same-flow-electrical-voltage-observations)
defines `flow.observeVoltages(pairs:limits:cancellation:)`. Actual positive/reference
Node pairs yield an immutable private-init observation owner with `pair`,
`initialVoltage`, `windowVoltage` and `almostEverywhereRate` in V, V and V/SI-second.
Its explicit `public let flow: NativePrescribedVoltageFlow` is the EXACT invoking
retained owner. Derive preparation, time, source and profile scope EXCLUSIVELY
through `observations.flow.withScope`. A separately supplied Flow plus observation
rows cannot form this join; copied CE rows alone are not authority. This lower capability is supplied by public Core
`40eefa8efe9960def7d7151298e96f898cbebab2`. Physical consumes its checked
electrical node/gauge and value/rate contract; it does not inspect Evolution payloads, derive rates from point
Jacobians or reconstruct model math. Any unproved internal-output premise makes
a WHOLE Timing/Native seal refuse.
Primary-source factual comparisons may be diagnostics, not a successful whole seal
or a new alternate facade. The missing observation cannot be interpreted as
permission to narrow the circuit/family.

The current initialRoots jointSlice has no finite-first-crossing, unique event,
slew-crossing or established cell-history guarantee. Proving normalized value/AE
rate membership alone does not prove those stronger obligations. A later complete
STA/event claim must additionally consume Timing's actual checked response/history
contract with the required source evidence; this child cannot invent that authority.

### Sealed result and admission

Publish a private-initializer immutable owned result only after all complete
joins succeed on the actual observation owner's `flow.withScope`. Retain candidate/proof/source
identities, original inputs/configuration, numeric PG/rail/gauge mapping, exact
contexts/joint slices, all independent and endogenous associations, the actual
Core observation owner (which retains its Flow) and lower reservations. Public data/diagnostic records grant no constructor or
executable authority. A result copy retains the same owners; no per-copy budget
or per-inspection array is created. Borrowed spans are lexical and cannot cross
await or escape their immutable owner.

## Declared Zero-Resistance Connections

The exact captured SPEF is the declared circuit model. An exactly positive-zero
binary64 resistor between two distinct canonical nodes declares the ideal
constraint V(a)-V(b)=0. This is mathematical netlist interpretation, not a new
layout/contact, extraction, foundry or PVT qualification. No decoded evidence,
profile string or caller boolean grants physical authority. Negative zero,
negative/nonfinite values and unsupported source forms do not silently become a
connection. The positive-resistor primitive and its finite r>0 admission stay
unchanged.

Original SPEF bytes/reference, cold passive multiset, ParsedSubcircuit rows and
the checked source-preparation circuit retain every resistor value bit and raw
endpoint. After their existing exact transfer check, an internal immutable
`PhysicalLogicWholeCandidateIdealConnections` maps only generated `whole_pex`
positive-zero R rows to the existing Native independent DC voltage-source
primitive with voltage exactly +0.0. The derived circuit keeps every node ID,
node name, instance name/order and all nonconnection instances unchanged. Each
mapped instance owns one new, checked unique branch ID. The original source is
never rewritten and the mapping retains its exact source component ordinal,
instance index and new branch identity. Thus the prepared Native F/Q equations,
not a per-model setup observation, implement the declared zero-resistance law:

```text
original R0(a,b) row retained
   -> Native V0(a,b), branch i
   -> F[a]+=i; F[b]-=i; F[branch]=Va-Vb; Q=0
   -> selected constant-zero source in the existing checked forest
   -> original endpoint voltage equality and reconstructed contact current
```

The constant-zero source uses zeroVoltage=oneVoltage=0, initial/window U=[0,0]
and SI a.e. dU/dt=[0,0]. It is an internal ideal-connection category, never an
independent Timing input or prescribed endogenous output. The Native source and
returned Flow scope must match each retained source row, signed endpoints, actual
instance/device index, fresh branch, DC waveform and selected zero law. Every
connection must occur exactly once; extra or missing sources fail. Cyclic or
redundant ideal constraints retain the existing forest's typed refusal instead of
being dropped or approximated. No rmin, alias collapse or generic R0 admission is
added to Core.

Only source assumptions are extended internally. All caller OriginalD endpoints,
initial/window Z/Y, algebraic selectors, dynamic-initial parameters and charge
boxes are passed unchanged and checked against the FINAL actual circuit/reduced
order. In particular, no branch-current domain bound or numerical hint is
synthesized. The retained source circuit and derived Native circuit have equal
instance/node counts; the mapping explicitly accounts for added branches and
changed primitive kinds before publication.

Construction pre-admits exact fixed arrays for derived instances, old+new branch
slots, mapping rows and selected-source slots, plus every new one-entry parameter
map and owned-branch payload, before allocation. Input nodes, names, source/model
backing and nonconnection values are immutable shared input; no physical duplicate
is claimed. The one existing operation control charges all scans/copies, checks
cancellation before/after reservations and keeps its original cumulative owner.
The result retains the connection mapping and construction lease with the source
preparation and actual Flow until the last result copy. No callback executes under
a lock; all new stored state is immutable on the existing host-only path.

The finite declared-connection profile is qualified. The retained
`qualification-r1.json` (SHA-256
`6e388df0c86db523d2664450535a1e268536d1b228c3224aa4070d11eaea0809`)
and one `root-review-r1.json` (SHA-256
`a49eb1c90711b8d3a5868355c4d8018424990c465a4c1131885784dc63531d89`)
bind 12 declarations / 13 cases / zero skips: four new connection tests and eight
affected whole-candidate tests. Completed unchanged tests are composed with the
single corrected pure RC test; failed CE bit-identity assertions are not counted
as success. The tests execute actual controlled Native F/Q and nonzero contact
current/charge evolution, both endpoint voltage and SI-rate enclosures, exact
positive-zero/distinct-node refusal, final-dimension refusal, cumulative resource
failure/cancellation and last-copy refund. The actual SDK case saves and cold
reloads the SAME checked R0 candidate, rereads its exact SPEF, and then constructs
a fresh live assessment/Native Flow; no decoded Flow authority is created.

Only the new helper's qualification marker is closed. The existing public
whole-candidate operation marker belongs to separate strict controlled Runtime,
STA and CLI completion and is retained. Global admissible initial-set inclusion,
the full actual 56-device/contact Native circuit, all-history continuation, PVT
and source-precision guarantees remain unproved; this finite evidence grants no
physical-contact/foundry qualification.

## Runtime Flows

1. Check actual assessment/Prepared STA and pre-admit candidate/source projection.
2. Read/check immutable original sources and full PEX on bounded actual providers;
   retain exact inputs, compose standard SPICE and verify cold passive equality.
3. Obtain checked Timing contexts and full joint slices under their existing owner;
   construct untrusted Core request values from outward complete projections.
4. Prepare the actual complete controlled Native owner with the same retained source
   resource ledger, then call its concrete conditional Flow operation.
5. Obtain qualified Core-owned observations from that actual Flow. Within lexical
   `observations.flow.withScope`, verify all source/model/rail/time/candidate
   associations and discharge every endogenous observation. No separately supplied
   Flow or unbound row table may replace this actual retained owner.
6. Close actual foreign/exclusive resources before publication; preserve pending
   cleanup and original failures if any close fails. Publish all joins or none.

Cancellation brackets artifact awaits, lower preparation/Flow awaits and result
publication. Source/normalization/RNG/work costs are never reset between phases.
The actual producer must not rebuild a new circuit/ledger merely to turn a refusal
into success.

## State, Ownership, and Lifecycle

| State | Owner and lifetime |
|---|---|
| Assessment, candidate, source/PEX bytes and correspondence | Immutable existing owners retained by the operation/result; separately admitted projection containers |
| Timing context/joint slices | Actual checked Timing owner and original state/work reservations; retained to last result copy |
| Native circuit/model state | Existing exclusive controlled owner; close via its actual API, without public device history exposure |
| Flow/scope values and observations | Core-owned immutable observation owner retains its EXACT Flow/leases; Physical never retains a borrowed span |
| Join maps and metadata | This child's pre-admitted logical payload, one shared invocation ledger; no global cache |
| Failed cleanup | Existing lower pending/retry capability, or the component's exclusive-staging retry actor, retained with original primary and secondary causes |

Cross-domain work owners remain their original authorities, with an explicit
invocation admission that accounts for their concurrent retained payloads. No
fresh per-cell/per-slab work allowance or hidden source-budget reset is allowed.
Reserve byte/count/copy capacity with checked arithmetic before each owned growth;
account simultaneous candidate/source/PEX, Native floor/program, Timing slices,
Flow result and join workspace. Existing allocator/RSS exclusions remain explicit;
logical managed byte checks do not become a hard RSS guarantee. Foreign calls,
I/O and user callbacks never execute under a Mutex. New shared mutable state, if
needed, must use one unconditional isolation owner on all supported host paths.

### Local quota isolation

| Logical state | Storage | Read/mutation | Release |
|---|---|---|---|
| Physical join live+temporary bytes | One unconditional `Mutex<UInt64>` in the immutable operation control | Short checked admission/refund only | Each composed lease refunds exactly once |
| Original invocation resource ledger | Existing caller-supplied `SPICESourceResourceAccounting` | Forward the same charges/reservations; bracket with operation cancellation | Original reservation owner |
| Exclusive staging identity/write/removal state | One private actor with the same state on every supported host path | Serialized initialization, write, removal and retry; no cancellation during cleanup | File lease after removal; metadata/path lease after final owner copy |

No external accountant callback, I/O, source parser, foreign call or await occurs
under the join quota Mutex. The callback-bearing original lease is retained and
released outside that lock. Result metadata and fixed symbol tables use the join
quota; accounted Timing slice slots use the same quota through a narrow accounting
projection. Lower Native/source reservations keep their original phase ceilings
and cumulative source ledger. There is no target-specific storage branch or raw
mutable alternate state; the component's current execution target is host-only.

## Failure, Concurrency, and Constraints

Failures preserve typed candidate/source/PEX/model/rail/time/family/internal-output,
resource, cancellation and lower numerical refusal distinctions. Preserve the
original lower cause and any secondary cleanup error plus its actual retry owner.
A successful partial phase is not a successful seal. No source, numerical,
profile or budget fallback is allowed. The operation is host-only; no new
WASM/Embedded, all-history, source-family existence or release-readiness proof
follows from native tests.

## Verification and Change Impact

| Fixed invariant | Required falsifiable evidence after implementation GO |
|---|---|
| Actual whole candidate | Checked save/reload -> original five-source/PEX composition -> controlled whole Native; all leaves, full pins/PG/body/Given, every passive kind/endpoints/value bits/multiplicity compared |
| Actual independent family | Real unrestricted and clock contexts from actual Prepared STA; constant-member mismatch and isolated derivative exclusion refuse; no fabricated point family |
| Endogenous response | Actual inverter output remains an unknown; wrong endpoint, added output V, missing/extra internal premise, wrong source arc/load/threshold or unproved voltage/rate membership refuse whole seal |
| Exact scope | Mutate candidate/corner/source/rail/gauge/DD-time/PEX bit/body Given/ambient/nominal/model identity one at a time; reject exact typed join failures, not any unrelated throw |
| Complete successful join | Actual checked public lower values and whole circuit; endpoint oracle/retained scopes inspected; conditional claim remains correctly bounded |
| Shared owner | Pre-spent work, pre-growth tight byte refusal, mid/postawait cancellation, actual pending cleanup retry, copied-result final refunds, no partial publication |

Tests belong in `PhysicalLogicHandoffTests` and must use ordinary published lower
APIs for the actual path. Historical setup/model tests and synthetic finite Core
fixtures cannot replace a whole-candidate successful producer and its negative
joins. Run one stable focused implementation qualification and scoped review after
all required lower gates close; package/task integration remains root-owned.

The implementation targets public Core `5fa29e8accb1ff9de0d1e5f8bc9efe128accf0b7`,
Timing `d6d0bec0ee5b97a25687ad0db02e127b6d3a9df0` and PEX
`b1bbf83af9218590ff47bb6c8c31482a1dd03bb0`. The coherent public PDK selector is `d27217e8312c072f4fde731d722e48f3040d5a5b`;
Logic is `3b3db10ddd8aa4cfb0e938da6644999f1feba5bb`. All selectors must
resolve exactly before build qualification. Original model constitutive and smooth
capabilities must still be present on the actual provider/program/profile. Prior
setup success does not supply absent source proof. The complete Sky130 source
program, initial cover, continuation and history remain separate open authorities.

### Frozen implementation interface

The existing `PhysicalLogicECOAssessment` owns the direct operation:

```swift
public func certifyWholeCandidateFlow(
    preparedSTA: PreparedSTAExecution,
    request: PhysicalLogicWholeCandidateFlowRequest,
    limits: PhysicalLogicWholeCandidateFlowLimits,
    context: inout LogicKernelContext,
    resources: any SPICESourceResourceAccounting,
    cancellation: CancellationToken,
    isolation: isolated (any Actor)? = #isolation
) async throws(PhysicalLogicWholeCandidateFlowFailure) -> PhysicalLogicWholeCandidateFlow
```

All public request records are untrusted values. They supply existing lower
inputs rather than a prebuilt Flow or a proof callback:

| Request field | Exact type and meaning |
|---|---|
| `source` | `SPICESimulationPreparationRequest`: checked original base source/catalog, unchanged normalization/seed/temperature and exact include policy |
| `spefReference`, `spefBytes`, `pexCorner` | `ArtifactReference`, `Data`, `PEXCornerID`: exact captured SPEF; verify digest/length and decode these owned bytes through public PEX primitives |
| `cellInstances` | `[String: String]`: physical cell ID to original root SPICE X name; total, injective and checked against actual parsed master/port order |
| `pinNodes` | `[String: String]`: physical signal pin ID to actual root SPICE node; total and checked against parsed X terminals and complete PEX membership |
| `rail` | `PhysicalLogicWholeCandidateRail`: `sourceName`, `zeroNode`, `oneNode` (`String`) and `zeroVoltage`, `oneVoltage` (`Double`); check actual source orientation, all original PG/body ties and observed Liberty voltage |
| `sourceBindings` | `[PhysicalLogicWholeCandidateSourceBinding]`: each `sourceIndex: Int`, `physicalPinID: String`, `sourceDeviceName: String?`; exactly one entry for every canonical Timing source; only primary entries have an independent V source |
| `timingContext` | `STAConservativeSourceContextRecord`: reconstruct against the SAME `preparedSTA`; never treat decoded values as authority |
| `initialTimeSI`, `windowSI` | `ClosedRange<Double>`: retained Timing projection hulls containing exact DD initial time and the full outward Native window |
| `native` | `PhysicalLogicWholeCandidateNativeInputs`: existing optional `SPICEOSDIRuntimeInputs`, optional `NativeConstitutivePreparationInputs`, optional `OSDIConstitutiveCaptureInputs`, optional `OSDISmoothRangeCaptureInputs`, plus the existing `NativePrescribedVoltageFlowRequest` |

The initial rail profile admits one explicitly grounded zero rail (`zeroNode` is
actual ground and `zeroVoltage` is zero) and a finite positive rail difference.
Other gauges/rail systems fail explicitly rather than being translated. Signal
normalization uses the actual retained rail difference; it cannot reinterpret
floating internal coordinates as ground. No candidate- or cell-count restriction
is introduced.

`PhysicalLogicWholeCandidateFlowLimits` stores the existing
`PhysicalLogicHandoffLimits`, `SPICENativeExecutionLimits`,
`NativePrescribedVoltageFlowLimits` and
`NativePrescribedVoltageFlowObservationLimits`, plus explicit positive
`maximumSourceBytes`, `maximumSPEFBytes`, `maximumComposedBytes`,
`maximumJoinBytes` (`UInt64`) and `maximumAssociations` (`Int`). Native numerical
limits come from the SAME checked SPICE effective configuration. The source
accountant supplied to the operation remains the cumulative allocation/work owner;
these phase ceilings never replace or reset it.

`PhysicalLogicWholeCandidateFlow` has no public initializer. Its public retained
values are `assessment`, `preparedSTA`, `sourcePreparation`, `observations`,
`timingContext`, `jointSlices` and `rail`. `jointSlices` is an existing
`SPICEAccountedCollection<STAConservativeSourceJointSlice>` so a copied collection
retains its own slot lease even when the parent result is released. Every value is produced or checked by
the actual direct operation. `observations.flow` is the sole Native scope
source; neither a separately supplied Flow nor copied observation rows are
accepted. Copies retain the same lower owners and one admitted join payload.

`PhysicalLogicWholeCandidateFlowFailure` preserves distinct typed cases:
`invalidInput`, `candidate`, `source`, `parasitics`, `rail`, `time`, `family`,
`internalOutput`, `resource`, `cancelled`, `native`, `lower` and `cleanup`.
`lower(phase:cause:)` retains the original lower candidate/source/PEX/Timing error
without flattening it to a diagnostic string. Local family/internal-output failures
retain the canonical association index and a static reason; other local guards use
static phase-specific reasons. They do not construct unadmitted concatenations of
caller-controlled identifiers during failure. The exact candidate/source/mapping
input remains the caller's retained context for locating that failed premise. Lower causes and any
actual cleanup retry owner remain retained; errors never construct a partial seal.
At the actual independent-voltage-source inspection borrow only, unwrap a
`NativeVoltageSourceInspectionFailure.callback` whose underlying cause is exactly
`PhysicalLogicWholeCandidateFlowFailure`, and rethrow that same local cause.
This preserves the producer's family/rail/source/resource/cancellation categories
and their original payloads. Every other inspection case and every foreign
callback cause remains the original Native failure; this is not a general nested
error normalization rule.

The base source is not itself an electrical certificate. The producer validates
its complete root inventory and original cell declarations against the assessed
candidate, applies the public PEX composer internally, cold-checks passive
kind/endpoints/value-bit multiplicities and lowers that exact composed source.
It does not accept a caller-provided `CircuitIR`, passive multiset, setup receipt,
Flow, observation table or whole-result constructor as substitute authority.

Production ownership is this child plus the parent assessment extension and
necessary manifest composition. Test ownership is exclusively
`Tests/PhysicalLogicHandoffTests/WholeCandidateFlow*`; the test owner uses the same
public direct producer, including finite actual-SDK positive fixtures and explicit
missing-full-Sky130-program refusal. Tests and production share the isolated exact
public-baseline checkout, with no primary private ancestry or source replacement.

### Controlled PEX construction and source transfer

Adopt public PEX `b1bbf83af9218590ff47bb6c8c31482a1dd03bb0` and its
[controlled parser contract](../../../../PEXEngine/Sources/PEXParsers/DESIGN.md).
One immutable adapter forwards `checkpoint(workUnits:)` and `.temporary` /
`.retained` reservations directly to this operation's original source accountant
and cancellation token. There is no second work counter, quota reset, or legacy
success path. Lower reservations remain part of the original invocation ceiling;
Physical's join ceiling additionally bounds its own text, byte, map and transfer
payloads. Opaque Foundation runtime workspace and allocator buckets are outside
logical managed payload; materialized text/Data/container values are inside it.

Verify the captured SPEF byte count and complete digest against the exact
revalidated Prepared STA artifact reference before parsing. Decode those bytes,
then use controlled lexer, parser and lowering with the checked execution-corner
label. Validate every physical signal terminal and canonical passive. Use the
controlled writer, cold-parse its generated fragment through controlled Magic,
and require complete kind/oriented-endpoint/binary64-bit multiplicity equality.
Use the controlled composer on the unchanged original root and lower that exact
composed root with the original include catalog, external model policy, scalars,
RNG and operating conditions. The actual lowered `whole_pex` declaration/call and
every flattened generated passive must match the cold canonical fragment.

The cold Magic identity profile rejects unrelated original R/C cells, so it is
not used as a general parser for the full composed deck. Original cell bodies
remain untouched and are parsed/lowered by Core's actual source owner. The
fragment equality plus actual composed-source generated-section equality closes
the passive transfer without filtering, a private parser, or a fabricated IR.

Each lower returned semantic value stays beside its exact immutable retention
anchor while shared. Lexical operation scopes retain all six anchors through
full-source preparation and passive validation. The generated root is transferred
through accounted Core byte/text admission, creating separately owned source
storage; no PEX token/tree/IR/String view is published in the result. Phase anchors
can then release. The returned source preparation retains its original root,
provider, catalog reservation and new accounted root through all shared copies.
Controlled PEX source failures preserve their admitted cause/anchor inside
`lower(.parasitics,cause:)`; original accountant and cancellation failures retain
their resource/cancel classification.

Magic's public file-input contract uses one exclusive operation temporary
directory for the generated fragment only. Admit explicit URL/path, Data, raw
input-array and file payload before materialization; check the original control
before/after atomic Foundation I/O. Owned byte/hash/copy loops check in bounded
pages. Remove the directory before publishing any source result. Cleanup failures
retain original cause, secondary filesystem cause and exact retry location; they
cannot become a whole-success seal. Filesystem/Foundation atomic-call internals
are not claimed cooperatively interruptible. No external artifact is overwritten.

### Exclusive staging cleanup ownership

No applicable public immediate filesystem owner supports removal/retry of this
producer's private directory. `PhysicalLogicWholeCandidateStagingCleanupFailure`
is therefore a component-specific public error: original optional primary,
secondary cause, exact directory URL and `retry() async throws`. Its initializer
is internal; every copied failure retains the same private actor and original
admitted metadata/path/file reservations. `stagingCleanup` is a distinct public
whole-candidate failure case. It is not a successful source or electrical seal.

The private actor atomically creates one unique directory (`mkdir`, mode 0700),
records native device/inode identity with `lstat`, writes only its own fragment,
and serializes removal/retry. Before removal it checks that exact native identity
and directory kind; a detected replacement is never removed. Missing-before-
success is an explicit pending failure, not success. A successfully verified
removal records completion, making later retries idempotent. If identity cannot
be established after creation, cleanup remains explicitly unverified; it cannot
adopt a later path as the original. External repair/manual inspection may be
necessary rather than deleting an unproved replacement.

This is an exclusive same-operation staging contract. Identity checking and
Foundation removal do not constitute an atomic compare-and-remove primitive
against a hostile same-UID process racing path replacement. No such adversarial
filesystem guarantee is claimed. The narrow host C ABI borrows Foundation's
NUL-terminated path only within the closure, uses initialized stack `stat`,
checks length/arithmetic, and stores only numeric identity; no pointer escapes,
shared raw state, manual buffer allocation or deallocation is introduced.

Cleanup is always awaited on success and failure, even after invocation/Task
cancellation. The actor's synchronous removal deliberately has no cancellation
checkpoints; Swift actor hopping does not implicitly cancel this work. Primary
resource/cancellation errors remain primary if cleanup also fails. File-payload
reservations refund after successful removal; actor metadata/path/error capacity
remains until the last copied owner disappears. A failed initialization after
successful directory creation also retains the actor in the public failure.
The parent phase cannot publish success before removal completes.

Focused tests must exercise real directory retreat/replacement, restored retry,
idempotent retry, failure-copy retention/final refund, and cancellation cleanup.
