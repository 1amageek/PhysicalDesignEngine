# Native capability and limitation report

## Executable capability

The native implementation accepts a `PhysicalDesignRequest` carrying a canonical `PhysicalDesignSnapshot` and performs deterministic, reviewable mutations for:

| Stage | Native behavior |
|---|---|
| Floorplan | Die/core geometry and placement rows |
| Power planning | Connected source/sink power nets, rings, straps, rails and checked rail/strap vias |
| Placement | Deterministic row-based legal placement |
| CTS | Clock buffers, branch-net connectivity, physically materialized clock routes/vias and estimated skew/latency |
| Global/detailed routing | Deterministic Manhattan route candidates and via records |
| Timing/DRC ECO | Typed resize, move, buffer, reroute and blockage actions |
| Antenna repair | Jumper repair candidates and ratio update records |
| Fill insertion | Deterministic windowed fill candidates |
| Redundant vias | Redundant via candidates from existing vias |
| Hotspot repair | Reviewable hotspot resolution candidates |

Every completed stage emits a new canonical JSON revision, DEF handoff, and `XcircuiteDesignDiff`. Every artifact has a SHA-256 digest, byte count and producer run ID.

Every completed stage also emits a run manifest binding the design digest, timing constraints, PDK identity, base revision, proposed revision, design diff, implementation configuration, deterministic seed and implementation identity.

The package now exposes an additive `CircuiteFoundation` boundary. `PhysicalDesignFoundationEngine` adapts the native executor to the shared `Engine` vocabulary, `PhysicalDesignFoundationEvidence` exposes a stable evidence packet, and `PhysicalDesignFoundationArtifactConversion` rejects legacy references without verified SHA-256 and byte-count metadata. Xcircuite request/result/manifest types remain compatibility models for the current runtime ledger.

The M5 review boundary exposes a typed human-in-the-loop contract:

| Review operation | Native behavior | Evidence |
|---|---|---|
| Prepare review | Loads a completed manifest, revalidates all referenced artifact bytes/digests, and creates a Codable decision packet | `PhysicalDesignReviewPacket` |
| Evaluate decision | Accepts only a decision bound to the packet's run, stage, manifest digest, proposed revision and complete scope | `PhysicalDesignReviewResult` |
| Validate resume | Requires approval and rechecks run/stage, embedded manifest, current bytes/digests for every artifact, base revision, proposed revision and decision scope | `PhysicalDesignResumeRequest` and structured stale diagnostics |

The packet and decision are immutable value types suitable for Xcircuite artifact persistence. The native gate does not overwrite layouts or approvals; the sibling Xcircuite runtime owns the run ledger and resume orchestration.

M3 also persists `implementationState` in the canonical snapshot:

| Evidence | Native behavior |
|---|---|
| Tracks / power domains / pads | Generated deterministically during floorplan when absent |
| Placement proof | Reports legal cells, overlaps, core bounds, blockage attempts, utilization and timing/congestion proxy objectives |
| CTS state | Materializes clock buffer cells, branch nets, clock routes/vias and clock route constraints including transition limits |
| Routing evidence | Selects directional layers, emits non-degenerate bend vias, checks core/blockage/spacing/via constraints and records antenna-risk nets |

M4 repair behavior is qualification-aware at the native contract boundary:

| Repair | Native behavior | Evidence |
|---|---|---|
| ECO | Applies typed cell/net/blockage actions, splits and reroutes buffer ECO connectivity, and rechecks the native snapshot | `RepairProof` |
| Antenna | Supports jumper, reroute and protection-device strategies | Ratio result, strategy and repair proof |
| Fill | Uses window spacing, density, cell, blockage and power-structure exclusions | Fill proof and density checks |
| Redundant via | Searches spaced candidate offsets and rejects conflicting candidates | Via spacing proof |
| Hotspot | Applies a bounded repair window and checks core/cell conflicts | Resolved hotspot and repair proof |

## Layout interchange

The native interchange boundary is:

| Format | Input | Output | Status |
|---|---:|---:|---|
| Canonical JSON | Yes | Yes | Native canonical format |
| DEF 5.8 supported subset | Yes | Yes | Rows, components, pins, nets, routes, blockages and power structures |
| GDSII | No | No | Protocol-first external adapter; blocked until qualified |
| OASIS | No | No | Protocol-first external adapter; blocked until qualified |

DEF parsing returns typed diagnostics with `code`, `line`, `section`, `entity` and suggested actions. Component dimensions default when the DEF source does not provide a supported size extension; the diagnostic remains attached to the run. Source format, source digest, parser ID and parser version are persisted in `run-manifest.json`.

## Fail-closed behavior

The backend returns `blocked` for missing canonical state, unsupported opaque layout formats, invalid geometry, missing placement rows, missing clock or net semantics, and missing repair targets. It returns `failed` only when it cannot produce a valid result envelope, such as artifact persistence failure. Cancellation is preserved as `cancelled`.

## Qualification boundary

This implementation is deterministic and fixture-tested, but it is not process-qualified. DRC, LVS, PEX and Timing remain independent oracles. Timing and congestion objectives are native proxy metrics, not signoff timing. Native antenna, DFM and hotspot operations produce repair candidates with native verification proofs and never claim signoff. GDSII/OASIS stream-out requires a qualified external adapter and is fail-closed through the adapter gate. Tool trust, process qualification, reference correlation and release approval remain Xcircuite/ToolQualification responsibilities.
