# PhysicalDesignEngine Remaining Tasks

Updated: 2026-07-26

The deterministic native geometry-smoke backend and callable OpenROAD process
backend are implemented. Production readiness remains evidence- and
integration-gated.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
| PHY-1 | P1 | PhysicalDesignEngine and qualification workflow | Retain real process-specific physical corpus, independent oracle, and health artifacts. | Actual OpenROAD/PDK runs retain exact executable, process, PDK, RC, Liberty, corner, input/output, and oracle identities and can be reconstructed by ToolQualification. |
| PHY-W3 | P1 | Xcircuite / DesignFlowKernel integration | Add end-to-end flow fixtures for the external backend. | A retained run covers execution, raw evidence, failure, review, approval, resume, downstream signoff handoff, and immutable artifact verification. |

## External prerequisites

An installed OpenROAD executable, exact PDK views, and independent process
evidence are external inputs. Native geometry success is not production
qualification.

PHY-1 and PHY-W3 specifically require those real external inputs. They cannot
be completed by adding process data, mask I/O, trust policy, or flow lifecycle
ownership to PhysicalDesignEngine.

## Completed host P1

| ID | Completion evidence |
|---|---|
| PHY-W1 | Xcircuite composes canonical layout outputs with `LayoutIO.MaskDataFormatConverter`, retains GDSII/OASIS artifacts, verifies standard-layout round trips, and routes those artifacts into downstream LVS/PEX stages. Mask encoding remains owned by `swift-mask-data`/`semiconductor-layout`. |
| PHY-W2 | Xcircuite consumes typed DRC/LVS/PEX/Timing/Electrical feedback, formulates auditable repair plans, retains rejected feedback, applies reviewable mutations and design diffs, re-runs gates, and preserves approval/resume state. PhysicalDesignEngine continues to own physical mutations rather than signoff verdicts or flow policy. |

## Evidence reviewed

- `README.md`
- `DESIGN.md`
- `INTERFACES.md`
- `IMPLEMENTATION_PLAN.md`
- `MILESTONES.md`
- `GOAL_STATUS.md`
- OpenROAD execution and native invariant paths
- `Sources` incomplete-implementation marker scan
