# PhysicalDesignEngine Requirements

## Goal

Transform a mapped design into a traceable physical implementation and close repairable physical constraints.

## Required functions

| Function | Required behavior | Priority |
|---|---|---:|
| Floorplan and IO planning | Create die/core geometry, hierarchy placement, pins, pads and blockages. | P0 |
| Power planning | Create rails, straps, rings, vias and domain-aware power connectivity. | P0 |
| Placement | Perform global and detailed legal placement with timing and congestion objectives. | P0 |
| Clock-tree synthesis | Construct physical clock trees with skew, latency, transition and routing constraints. | P0 |
| Routing | Perform global and detailed routing with layer, via and antenna awareness. | P0 |
| Physical ECO | Apply typed timing, DRC, antenna and connectivity repair actions. | P0 |
| Antenna repair | Apply reroute, jumper or protection-device strategies without owning the DRC verdict. | P1 |
| Physical DFM | Insert window-aware fill, redundant vias and hotspot repairs. | P1 |
| Immutable revisions | Emit layout revisions, DEF/GDS/OASIS artifacts and machine-readable design diffs. | P0 |

## Required outcomes

- Every mutation produces a new physical-design digest.
- DRC, LVS, PEX and Timing remain independent verification or analysis oracles.
- Xcircuite can iterate repairs and resume after human approval.

## Common platform requirements

- Public execution surfaces are protocol-first, Sendable and dependency-injected.
- Requests and payloads are Codable, Hashable and schema-versioned.
- Inputs and outputs use immutable XcircuiteFileReference artifacts.
- Diagnostics contain a stable code, severity, affected entity and suggested actions.
- Unsupported semantics and missing prerequisites produce blocked results.
- Native and external-tool backends conform to identical request and payload schemas.
- Execution capability, corpus validation, oracle correlation, process qualification and release approval remain distinct.
- Xcircuite owns flow construction, artifact persistence, qualification gates, repair loops, approval and resume.
- The package never imports Xcircuite or circuit-studio.

## Required developer surfaces

- Typed API
- Deterministic JSON CLI
- Positive and negative fixtures
- Contract and parser round-trip tests
- Reference corpus
- Capability and limitation report
- Xcircuite stage adapter tests
