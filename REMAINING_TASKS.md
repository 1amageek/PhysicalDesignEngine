# PhysicalDesignEngine Remaining Tasks

Updated: 2026-07-26

The deterministic native geometry-smoke backend and callable OpenROAD process
backend are implemented. Production readiness remains evidence- and
integration-gated.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
| PHY-1 | P1 | PhysicalDesignEngine and qualification workflow | Retain real process-specific physical corpus, independent oracle, and health artifacts. | Actual OpenROAD/PDK runs retain exact executable, process, PDK, RC, Liberty, corner, input/output, and oracle identities and can be reconstructed by ToolQualification. |
| PHY-W1 | P1 | Host integration | Compose canonical physical outputs with `swift-mask-data` for GDSII/OASIS export. | The host flow exports immutable standard-mask artifacts, verifies round-trip identity and geometry, and qualifies the concrete exporter without adding mask I/O ownership to PhysicalDesignEngine. |
| PHY-W2 | P1 | Host integration | Integrate DRC, LVS, PEX, and Timing feedback into the physical ECO loop. | Typed external feedback produces reviewable mutations and design diffs, then re-runs the required gates; native proxy checks never substitute for signoff. |
| PHY-W3 | P1 | Xcircuite / DesignFlowKernel integration | Add end-to-end flow fixtures for the external backend. | A retained run covers execution, raw evidence, failure, review, approval, resume, downstream signoff handoff, and immutable artifact verification. |

## External prerequisites

An installed OpenROAD executable, exact PDK views, and independent process
evidence are external inputs. Native geometry success is not production
qualification.

## Evidence reviewed

- `README.md`
- `DESIGN.md`
- `INTERFACES.md`
- `IMPLEMENTATION_PLAN.md`
- `MILESTONES.md`
- `GOAL_STATUS.md`
- OpenROAD execution and native invariant paths
- `Sources` incomplete-implementation marker scan
