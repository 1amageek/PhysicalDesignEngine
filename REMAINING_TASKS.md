# PhysicalDesignEngine Remaining Tasks

Updated: 2026-10-01

Native deterministic geometry and a scalar technology subset are executable.
Native production physical closure is not implemented. OpenROAD execution belongs
to EDAInteroperability and cannot close a native algorithm gap in this package.

The authoritative package outcomes and acceptance conditions are
[N1-N6 in IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md#remaining-native-work).
The active cross-package execution graph is [LSI PROGRESS.md](../PROGRESS.md).
Previous package sprint records are retained in [PROGRESS.md](PROGRESS.md).

| Responsibility | Remaining owner |
|---|---|
| Process views, cell/pin shapes and legal via/contact rules | PhysicalDesignEngine consuming exact PDK/standard-view contracts |
| Timing-driven placement, characterized CTS and bounded routing | PhysicalDesignEngine |
| Extraction/timing-driven native ECO | PhysicalDesignEngine with independent PEX/STA/DRC/LVS contracts |
| Exact standard interchange and semantic loss | PhysicalDesignEngine and standard-format owners |
| Independent process qualification | ToolQualification with retained native and independent observations |
| Same-design repair, human review/resume and release | Xcircuite, DesignFlowKernel, circuit-studio and ReleaseEngine |

Installed external tools and process assets are qualification inputs; their
availability does not implement the missing native responsibilities. Historical
host fixture handoffs do not prove a current production repair/release path.
