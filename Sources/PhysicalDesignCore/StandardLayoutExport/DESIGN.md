# Standard Layout Export

## Purpose and Scope

Provide public, source-bound deterministic DEF pairing for an immutable native
proposed snapshot and its retained request. Parent: [Core](../DESIGN.md). No children.

## Responsibilities and Boundaries

Own exact source pairing, invocation budgets, verified source reads and bounded
serialization. Reuse ProcessInputs, ProcessGeometry and the native DEF writer.
Do not execute a physical stage, alter snapshot evidence, publish artifacts, or
claim arbitrary DEF semantic equivalence. Canonical JSON remains resume authority.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent | Snapshot/request/store | Public composition | No canonical mutation |
| [ProcessInputs](../ProcessInputs/DESIGN.md) | depends on | Exact manifest/asset intake | Existing source reader | Read adapter independently verifies bytes |
| [ProcessGeometry](../ProcessGeometry/DESIGN.md) | depends on | Constructor and snapshot admission | Existing geometry owner | No projection exposed publicly |
| [RoutingGeometry](../RoutingGeometry/DESIGN.md) | depends on | Native DEF profile | Same writer as native publication | Exact single-RECT top ports; special nets still fail |

## Architecture

```text
snapshot + retained request + explicit limits
  -> exact source reference comparison -> bounded verified read adapter
  -> ProcessInputs.load -> precharged source/instance vertex projection
  -> ProcessGeometry -> snapshot validation -> shared bounded DEF writer -> Data
```

## Contracts and Invariants

`PhysicalDesignStandardLayoutExporting.exportDEF(snapshot:request:artifactStore:limits:)`
returns bytes equal to the native producer's DEF writer for the same admitted
snapshot and source request. Sources must be present: snapshot manifest and the
complete asset-ID/reference map equal the request, with retained input provenance
and unique bindings. Actual bytes must match declared SHA-256 and byte count.
All caller limits are required UInt64 values; zero intentionally refuses work.
Input bytes charge snapshot identifiers used by DEF plus cumulative source reads;
reference bytes are charged before I/O and names before interpolation.
Geometry records count manifest assets/layers/aliases/mappings, source declarations
and projected vertices. A RECT has five
closed vertices; a POLYGON has its declared vertices plus closing vertex. PORT VIA
references charge every selected fixed-via vertex conservatively. Source vertices
are multiplied by one source construction plus every cell instance and twice every
snapshot via (admission and writer). Checked arithmetic rejects overflow before
projection. Snapshot collections and nested net/route records are charged too.
This is a conservative vertex admission ceiling, not a signoff or timing budget.
The existing vertex-dependent geometry kernel remains the sole geometry owner.

The writer's shared text accumulator charges each UTF-8 fragment before appending
it to the retained output; net connections/routes/vias emit incrementally, avoiding
an unbounded intermediate net line. Final Data is an output-boundary allocation.
Fragments contain existing names and bounded integer formatting; no new serializer
or speculative format-size constants are used. An unsupported encoding fails before
any bytes are returned. All snapshot proof arrays remain unchanged.

## Runtime Flows

Cancellation is checked before reads, after reads, during record accounting,
before/after projection and at each serialized fragment. Cancellation is a typed
failure. A synchronous lower projection is not preemptible; its input vertex ceiling
is admitted first. Reads and hashing occur outside the budget mutex.

## State, Ownership, and Lifecycle

Every call owns a private read adapter, mutex-protected remaining byte budget and
immutable source projection. No cache, shared canonical state or artifact writes.
The caller retains snapshot/request/store ownership. Data is returned only on success.

## Failure, Concurrency, and Constraints

Typed failures distinguish source mismatch, input/geometry/output ceilings, source
preparation, snapshot admission, read, encoding and cancellation. Store allocation
is store-owned; reference limits precede read, actual count/hash follow it. Parallel
calls have independent budgets. No platform-conditional synchronization is introduced.

| State | Storage / isolation | Read and mutation | Release |
|---|---|---|---|
| Source-read byte budget | Private `Mutex<UInt64>` | `charge`, before I/O; no callbacks or await under lock | Export invocation releases adapter |
| Geometry accounting and DEF text | Invocation-local value | Exclusive local mutation | Export returns Data or throws |

This package's supported execution profile is host macOS. No WASM/Embedded runtime
qualification is claimed; no conditional storage or Sendable contract is introduced.

## Verification and Change Impact

[StandardLayoutExportTests](../../../Tests/PhysicalDesignEngineTests/StandardLayoutExportTests.swift)
compares actual native producer bytes with public export, retains proof bytes, and
rejects source substitution, forged store bytes, each budget and cancellation.
Changes to native writer formatting require the pairing fixture and existing DEF
producer tests; source admission changes require the corresponding lower tests.

Top-level single-RECT geometry, pose, net/direction/use and typed refusal are owned
by [TopPorts](../TopPorts/DESIGN.md). Their vertices and use/status identifiers are
charged before serialization; the public exporter does not infer geometry.
