# Checked Candidate Persistence

## Purpose and Scope

Own bounded atomic publication and checked reload of the exact physical candidate's
standard source netlist, raw RUP certificate and binding manifest.
Parent: [PhysicalDesignLogicHandoff](../DESIGN.md). No children.
This component extends the existing equivalent-assessment path; it does not create
an artifact store, perform SAT search, qualify geometry or grant timing/production
acceptance.

## Responsibilities and Boundaries

This component joins the already checked baseline and assessment to an exact saved
physical snapshot, exports standard names through the Logic-owned codec, and
reconstructs functional authority by independent certificate replay on reload.
The injected PhysicalDesignArtifactStore owns I/O and atomic publication. Logic
owns source semantics, realization and proof checking. Physical routing and PEX
remain independent consumers of the returned artifact references.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Handoff](../DESIGN.md) | parent / used by | Equivalent assessment and total correspondence | Checked candidate subject | Raw artifacts do not construct a checked verdict |
| [Serialization](../../../../LogicDesign/Sources/LogicDesignSerialization/DESIGN.md) | depends on | MappedGateVerilogCodec exact-name encode/decode | Standard source netlist | Preserve complete physical instance/net/port-bit names |
| [LogicProof](../../../../LogicEngine/Sources/LogicProof/DESIGN.md) | depends on | NativeLogicEquivalenceChecker.recheck | Independent saved RUP validation | No replacement SAT search or decoded proof status |
| [Runtime](../../../../LogicEngine/Sources/LogicEngineRuntime/DESIGN.md) | depends on | Checked synthesis and raw certificate codec | Exact baseline source authority | Stale/library-different baselines fail |
| [Core](../../PhysicalDesignCore/DESIGN.md) | depends on | PhysicalDesignArtifactStore and snapshot identity | Immutable candidate and atomic batch | No partial batch success |
| [Routing](../../PhysicalDesignCore/RoutingGeometry/DESIGN.md) | used by | Same-candidate source netlist and proof artifacts | Routed PEX handoff | Functional evidence does not qualify physical routing |

## Architecture

```text
checked assessment + exact saved candidate
  -> existing certificate replay + lower exact-name standard netlist
  -> injected store atomic [netlist, certificate, manifest]
  -> exact input reload + graph/problem reconstruction + independent replay
  -> checked assessment and same-candidate artifact references
```

## Contracts and Invariants


The manifest binds the baseline request, original design, mapped identities and
proof references, the exact saved physical snapshot, total correspondence,
netlist/certificate references and proof kind. Reload compares those premises to
an independently checked baseline, reconstructs the original candidate projection,
and rechecks the saved certificate without another SAT search. Raw artifact DTOs,
Codable correspondence, digests and manifest labels grant no functional authority.
Different candidates, stale baselines, altered masters/connectivity/library,
modified source bytes or invalid certificates fail before a checked return.

Positive graph limits, explicit per-artifact byte limits and the shared kernel
context admit reads, naming maps, proof payload and encode/decode work before
materialization. Checked arithmetic bounds the explicit payload reservation;
standard JSON codec internals do not provide interruptible allocation or an
allocator/RSS bound. Cancellation and typed resource/identity/store failures remain
failures. The batch publishes all three artifacts or none; it never publishes a
partial success receipt. The snapshot itself remains the previously saved exact
immutable candidate. Export/reload proves functional binding, not geometry, timing,
PEX, supply delivery or production qualification.

## State, Ownership, and Lifecycle

All working state is invocation-local. The operation retains the checked baseline,
immutable candidate and correspondence across awaited store operations under the
caller's isolation. Encoded buffers and explicit kernel storage reservations live
until publication/reconstruction finishes; normal and throwing exits release the
operation reservation. The store owns published immutable bytes. Returned raw
references may be serialized, but only reload reconstructs checked proof authority.

## Failure, Concurrency, and Constraints

PhysicalLogicCandidateArtifactError preserves typed binding, capacity, cancellation,
kernel, handoff and underlying I/O/codec failures. Positive per-artifact byte limits
are checked before reads; canonical graph/proof limits and the shared context bound
admitted transformations. Five byte-cap slots cover four retained encoded inputs
plus canonical re-encoding on reload. This is explicit buffer accounting, not an
allocator/RSS guarantee or interruptible opaque JSON decode. The store's atomic
batch is the only publication boundary, and a failed batch cannot yield successful
export references. No shared mutable service, retries or global cache is added.

## Verification and Change Impact

[CheckedCandidatePersistenceTests](../../../Tests/PhysicalLogicHandoffTests/CheckedCandidatePersistenceTests.swift)
checks saved checked replay, rebound netlist/certificate tampering, stale same-function
but different-library baseline, a different physical snapshot, byte/cancellation
limits, and a real atomic path conflict with no partial netlist publication.
[ActualSky130DetailedRoutingTests](../../../Tests/PhysicalLogicHandoffTests/ActualSky130DetailedRoutingTests.swift)
consumes exact saved API/CLI routing outputs and hands their checked source netlists
and DEF references to routed PEX. Lower naming/proof contract changes require this
component's focused consuming tests; geometry/timing qualification remains with its
own owners. Build/runtime evidence is recorded by the task's root verification owner.
