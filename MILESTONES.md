# PhysicalDesignEngine milestones

```mermaid
flowchart LR
  M0["Direct Foundation contract"] --> M1["Immutable artifacts"]
  M1 --> M2["JSON / DEF interchange"]
  M2 --> M3["Native geometry smoke"]
  M3 --> M4["Characterized CTS"]
  M4 --> M5["TQ evidence consumer"]
  M5 --> M6["Real backend and corpus"]
  M6 --> M7["Host policy and release"]
```

## M0–M3 — Complete for declared native scope

- Stage protocols conform directly to `CircuiteFoundation.Engine`.
- Results use Foundation artifacts, diagnostics, provenance, and evidence directly.
- JSON/DEF/diff/manifest artifacts are immutable and re-verifiable.
- Filesystem paths are workspace-relative and reject symlink escapes.
- All declared native stages have deterministic geometry behavior and typed blocked failures.

## M4 — Complete for characterized CTS contract

- Clock geometry uses DBU-only fields and constraints.
- Timing uses PS-only estimates derived from exact PDK/RC/Liberty/corner artifacts.
- Missing or invalid characterization blocks timing without converting geometry into time.
- Characterized timing does not change the production claim.

## M5 — Complete as a trust consumer

- PhysicalDesignEngine consumes canonical ToolQualification process evidence.
- Backend and oracle executables must be independent.
- A canonical ToolQualification oracle result derives agreement from raw outcomes and metric comparisons, while the physical consumer cross-binds the qualified stage, request scope and separate backend/oracle outputs.
- The native backend still blocks production intent.

## M6 — External evidence required

- Execute the callable OpenROAD placement/routing backend with an installed
  production tool and exact PDK views.
- Retain positive, negative, boundary, and regression corpora for concrete PDK profiles.
- Produce actual backend/oracle output artifacts and correlation records.
- Qualify the host-composed GDSII/OASIS encoders against real process
  artifacts.

## M7 — External production run required

- Supply accepted ToolQualification evidence to the implemented
  DesignFlowKernel approval/resume/release composition.
- Run independent DRC/LVS/PEX/Timing and downstream signoff engines on the
  real process fixture.
- Retain the implemented Xcircuite recovery and human-review path against that
  production fixture.

Production readiness remains blocked until M6 and M7 are evidenced by actual artifacts; source-level protocol presence is insufficient.
