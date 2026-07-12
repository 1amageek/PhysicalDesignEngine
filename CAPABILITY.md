# Native capability and limitation report

## Executable capability

The native implementation accepts a `PhysicalDesignRequest` carrying a canonical `PhysicalDesignSnapshot` and performs deterministic, reviewable mutations for:

| Stage | Native behavior |
|---|---|
| Floorplan | Die/core geometry and placement rows |
| Power planning | Rings and straps for declared power nets |
| Placement | Deterministic row-based legal placement |
| CTS | Clock source/sink tree records with estimated skew and latency |
| Global/detailed routing | Deterministic Manhattan route candidates and via records |
| Timing/DRC ECO | Typed resize, move, buffer, reroute and blockage actions |
| Antenna repair | Jumper repair candidates and ratio update records |
| Fill insertion | Deterministic windowed fill candidates |
| Redundant vias | Redundant via candidates from existing vias |
| Hotspot repair | Reviewable hotspot resolution candidates |

Every completed stage emits a new canonical JSON revision, DEF handoff, and `XcircuiteDesignDiff`. Every artifact has a SHA-256 digest, byte count and producer run ID.

Every completed stage also emits a run manifest binding the design digest, timing constraints, PDK identity, base revision, proposed revision, design diff, deterministic seed and implementation identity.

## Fail-closed behavior

The backend returns `blocked` for missing canonical state, unsupported opaque layout formats, invalid geometry, missing placement rows, missing clock or net semantics, and missing repair targets. It returns `failed` only when it cannot produce a valid result envelope, such as artifact persistence failure. Cancellation is preserved as `cancelled`.

## Qualification boundary

This implementation is deterministic and fixture-tested, but it is not process-qualified. DRC, LVS, PEX and Timing remain independent oracles. Native antenna, DFM and hotspot operations produce repair candidates and never claim signoff. GDSII/OASIS stream-out requires a qualified external adapter. Tool trust, process qualification, reference correlation and release approval remain Xcircuite/ToolQualification responsibilities.
