# Repair Measurement

## Purpose and Scope
Parent: [PhysicalDesignCore](../DESIGN.md). No children. Own source-bound antenna
and hotspot candidate measurement through the existing public NativeDRC backend.
The API completes missing measurement facts; it does not add a physical law.

## Responsibilities and Boundaries
Caller/profile owner supplies an exact profile artifact. ProcessGeometry owns
source PORT/OBS/fixed VIA and LEF gate/diffusion area declarations. NativeDRC owns
partial/cumulative surface/sidewall/diffusion calculations and typed rules.
RoutingGeometry owns reroute and finite upper-layer bypass construction.
LayoutVerify owns actual conductor contact/open/short capture. The executor owns
profile intake and atomic publication. Human approval and qualification are separate.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent | Exact native invocation/publication | Stage admission | Failed candidates publish no revision |
| [ProcessGeometry](../ProcessGeometry/DESIGN.md) | depends on | Exact polygons and named contacts | Source authority | No PORT-area substitution for gate oxide area |
| [RoutingGeometry](../RoutingGeometry/DESIGN.md) | depends on | Finite full-width routing | Candidate construction | CTS-owned family mutation remains rejected |
| [NativeDRC](../../../../DRCEngine/DESIGN.md) | depends on | Public NativeDRCBackend.run and NativeDRCRule | Existing laws | Clean verdict exposes no numeric antenna ratio |
| [SourceAntenna](../../../../DRCEngine/Sources/DRCNative/SourceAntenna/DESIGN.md) | depends on | Direct bounded source antenna input/result | Numerical source-law authority | Covered-domain partial laws only; Physical does not duplicate arithmetic |
| [LayoutVerify](../../../../semiconductor-layout/Sources/LayoutVerify/DESIGN.md) | depends on | Bounded exact conductor capture | Physical connectivity | No label-only connectivity proof |

## Architecture
```text
exact profile + exact process sources + snapshot
    -> actual polygon/band projection -> before NativeDRC + conductor capture
    -> finite unpublished candidate -> after same rules + conductor capture
    -> complete coverage and zero required violations -> atomic retained evidence
```

## Contracts and Invariants
The optional request repairMeasurementProfile binding identifies a schema-1 JSON
profile. It must appear in retained inputs with verified SHA-256 bytes; process
manifest and every process asset reference must exactly match the request.
Rules use existing NativeDRCRule values. Explicit process order may include
source CUT layers: a cut-stage rule requires its named cut rank between the
source lower and upper metals. Existing metal-only order profiles remain valid;
contacts become active at their explicit upper-metal stage in that profile. antennaLimitPolicy defaults to
legacyScalarLimit, admitting only the exactly corresponding simple partial law
and equal configured/net scalar limit. nativeRuleVerdict explicitly adopts the
supplied typed law (including cumulative/diffusion laws), rather than silently
reinterpreting a scalar-only request. Ordered process layer names, explicit
rule process steps/active layers and cut layer relations match actual fixed VIA
sources; layer parity and source names are not manufacturing order.
Target antenna nets are explicit. All their physical input/gate terminals require
finite positive source ANTENNAGATEAREA. The oxide area is attached once per
source pin, independently of the number of PORT polygons/bands. For schema-1 caller rules, diffusion correction requires explicit source
ANTENNADIFFAREA completeness. The [source-process policy](#source-process-antenna-measurement) owns the separate
retained-absence/report-zero contract.
Every checked target net/gate has actual same-net physical connectivity. Source
polygons are decomposed by the existing exact bounded rectilinear kernel.
Connectivity retains those integer extents, forming sizes and centers before
conversion to micron views; endpoint subtraction cannot introduce grid drift.

### Observational Route Projection and Source AREA

`PhysicalDesignRepairProjection` observes retained before/after surfaces; it is not
an AREA verdict or a conductor constructor. Every retained route still requires
its explicit qualified width and exact source width/spacing validation. That
read-only query sets `areaHandledSeparately: true` because projection neither
constructs nor alters metal. It retains the full endpoint-qualified footprint,
source correspondence and integer extent even when observing a deficient before
shape. It never declares that shape AREA-clean.

```text
Source AREA + actual retained route -> width/footprint observation -> raw measurement
Source routing constructor -> existing bounded AREA admission/repair -> candidate
    -> observation -> unchanged pre-publication geometry and serialization checks
```

[RoutingGeometry's AREA composition](../RoutingGeometry/DESIGN.md#bounded-area-routing-composition)
remains the AREA authority. Its constructor, repair, final replay and unsupported
stage gates remain active. A successfully completed routing candidate reaches
source-process measurement only after that owner's admission. Projection does not
add an AREA waiver, fabricated pass flag or independent AREA calculation, and
other conductor constructors do not inherit a new capability.

[SourceAreaRepairProjectionTests](../../../Tests/PhysicalDesignEngineTests/SourceAreaRepairProjectionTests.swift)
loads actual digest-bound LEF AREA declarations, observes above/below-threshold
route footprints without changing them, and rejects missing/wrong retained widths.
It also preserves the default constructor and unsupported-stage refusals. Existing
`RoutingAreaTests` and source-routing integration tests own AREA arithmetic and
construction behavior; the original-source antenna API/CLI case owns candidate
observation and filesystem publication/reload through this composition.

NativeDRC success is execution success; error-severity raw diagnostics are the
rule-violation authority. Antenna success requires at least one before violation, complete specified
rule/gate/net coverage, zero after violations under the same exact rules/sources,
and preserved terminal connectivity without shorts. Every requested net must have a
real before violation; every hotspot must have a before diagnostic with its exact
rule, intersecting hotspot region and selected source geometry. Projection-owned
exact source-ID correspondence distinguishes IDs containing delimiters; display
record prefixes cannot substitute for identity. Gate-layer filters
cannot omit a target gate. Cut relations completely cover named contacts whose
metal layers are present at that etch stage. Reroute uses the existing
finite router. Jumper bypasses transit on violating layers except within real
terminal PORT areas, using declared higher-layer tracks and named fixed contacts.
Unavailable layer/contact/path semantics fail. Protection insertion requires an
exact selected CORE master, explicit diffusion pin and every other pin's net
binding, source diffusion correction, legal row allocation and actual routing
of every touched net. All target and additional device-pin nets are captured
before/after; a new bias/power pin cannot remain physically open.

Hotspots require a typed source-bound constraint per hotspot ID. metalSpacing
selects an existing minimumSpacing rule and target net IDs; fillDensity selects a
maximumDensity rule with explicit window and target fill IDs; viaCutSpacing selects
a minimumSpacing rule on an exact cut layer and target redundant VIA IDs.
Candidates reroute selected nets around the hotspot window or remove selected
fill/redundant contacts. Resolution requires a real before violation, zero after
required violations and unchanged canonical terminal connectivity. A caller Bool,
severity text or newly added blockage alone cannot resolve a hotspot.

The new rule-verdict result retains exact before/after projected layouts and raw
NativeDRCExecutionResults in the run manifest. Legacy scalar antenna metadata is
not evidence. previousRatio/resultingRatio become optional: nil distinguishes a
clean rule verdict whose numeric ratio is not published by NativeDRC. Retained old
numbers remain unverified legacy values. A request for a numerical ratio fails
explicitly; the backend verdict is never converted to zero or a limit value.
Request schema remains 8 (with its existing limited legacy-7 admission) and
run-manifest schema remains 7 with additive optional profile/evidence fields; old requests preserve other stages and require the new facts for measured
repair. Snapshot schema 2 keeps old numeric values while admitting the new typed
rule verdict. Consumers must not arithmetic-unwrapping unknown values or interpret
legacy scalar records as qualified repair evidence.

## Runtime Flows
Load exact profile -> validate sources/coverage/budgets -> measured before ->
construct one finite candidate -> measured after and actual connectivity -> return
candidate plus raw evidence. Unsupported or failed repair retains the input.

## State, Ownership, and Lifecycle
All geometry, budgets and candidate state are invocation-local. NativeDRC receives
private temporary layout bytes through its public DRCRequest, with cleanup owned
by the same invocation. Final evidence retains the projection values/identities;
temporary paths are availability, not replay identity. No persistent cache or shared
mutable state is introduced.

## Failure, Concurrency, and Constraints
Caller selects positive input-byte, projection-record, geometry-probe and backend
work ceilings plus timeout. Projection and contact limits bound each of the two
phases; backend work and deadline are shared across all before/after rule runs.
Density window counts are charged before the backend loop. Checked structural work
admission precedes NativeDRC;
decomposition/capture share bounded lower contracts. Missing source facts,
unsupported profile/numeric-ratio requests, exhausted budgets, malformed geometry,
open/shorts, cancellation, NativeDRC failure or remaining required violations fail.
No production/process/lithography qualification follows from these observations.

## Verification and Change Impact
API and actual CLI prove measured reroute/jumper/protection and the three hotspot
predicates, with no-change/failed candidates, missing/changed source/rule facts,
unknown ratio, budget/cancellation and retained evidence replay. NativeDRC/geometry
law changes invalidate their dependent evidence. Host/DB/Release consumers adopt
optional metric and rule-verdict fields through root-owned exact dependencies;
old scalar records cannot substitute for new raw rule evidence.

## Source-Process Antenna Measurement

The explicit `sourceProcessLaws` policy requires profile schema 2, empty caller
`rules` and `hotspots`, explicit unique target nets, and an exact process layer
order matching the retained source projection. Schema 1 cannot select this policy.
The existing profile reference owns input bytes, projection records, geometry
probes, cumulative backend work, and one before/after deadline. Caller scalar
antenna limits and approximate `NativeDRCRule` values do not govern this policy.
Legacy policies keep their schema-1 behavior.

[ProcessGeometry](../ProcessGeometry/DESIGN.md) owns exact source law and terminal
projection; the public NativeSourceAntenna evaluator owns numerical laws and their
bounded evaluation. RepairMeasurement only binds each placed pin occurrence,
its complete PORT record identities, and actual fabrication-prefix geometry to
that contract. A source terminal's raw gate and diffusion declarations remain
separate from its reported diffusion contribution: covered omitted diffusion may
report zero, while missing gate coverage or opaque/unbound top PORTs refuse.
No PORT area, pin direction, Liberty capacitance, or caller threshold substitutes
for source gate/diffusion facts.
Exact mapped source layer types classify numerical interconnect: only ROUTING and
CUT records enter the numerical prefix input. Non-target MASTERSLICE, OVERLAP and
IMPLANT records retain explicit record/source IDs, mapped layer identity, type,
net and integer extents as nonconductor provenance. This classification describes
applicability to the selected ROUTING/CUT antenna model, not physical insulation.
Unknown/unmapped layers refuse.
A target terminal PORT on a nonconductor layer refuses rather than dropping PORT
coverage. Well geometry never supplies inferred gate or diffusion contribution. The source layer rule order, OXIDE1 scope, scalar
or inclusive-domain PWL law, and source artifact identities remain exact.
Unsupported laws, PWL domain escape, invalid numbers, incomplete identity/coverage,
quota exhaustion and cancellation refuse without publishing a candidate.

```text
exact sources + explicit schema-2 profile + candidate snapshot
    -> source law/terminal projection + all PORT and prefix geometry
    -> direct bounded NativeSourceAntenna evaluation
    -> exact input + raw result + candidate digest + measured coverage
    -> existing atomic manifest/snapshot publication
```

For antenna repair, every target net must have an actual before violation. The
existing finite candidate strategy must then preserve every terminal connection,
complete source coverage, and produce zero after violations under the same exact
sources and target set. Before and after consume one cumulative work allowance and
deadline; numerical arithmetic is not duplicated in PhysicalDesignEngine.

For other stages, an explicit source-process profile measures the exact successful
candidate once. The retained state distinguishes `clean`, `violated` and
`unassessed`; raw violations may be retained only with unqualified,
production-blocked execution. With retained antenna source laws and no explicit
source-process profile, the manifest records `unassessed`, never an antenna-clean
observation. Geometry/timing observations do not imply antenna assessment.

The additive optional source antenna evidence field keeps run-manifest schema 7.
Its absence on an older manifest means no source antenna assessment, and existing
legacy rule-verdict evidence is never reinterpreted as a source-process result.
New evidence retains exact process/profile references, candidate snapshot digest,
source-bound lower input and raw lower result per measured phase. Publication
checks these bindings and measured-state consistency. Native producer 1.12.0
identifies this new integration behavior; tool qualification remains blocked.

Focused API and actual CLI tests must verify successful candidate/save/reload
identity, source-process clean/violated/unassessed states, all-PORT single pin
accounting, omitted diffusion provenance, missing gate/opaque top-port refusal,
PWL boundary/domain refusal, unchanged legacy profiles, budgets, cancellation,
and failed-repair atomicity. Lower numerical tests remain owned by NativeDRC.
