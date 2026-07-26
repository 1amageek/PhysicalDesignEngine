# PhysicalDesignEngine Remaining Tasks

Updated: 2026-07-26

The deterministic native geometry-smoke backend and callable OpenROAD process
backend are implemented. Production readiness remains evidence- and
integration-gated.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
No package-owned P1 implementation remains.

## External prerequisites

An installed OpenROAD executable, exact PDK views, and independent process
evidence are external inputs. Native geometry success is not production
qualification.

PHY-1 and PHY-W3 specifically require those real external inputs. They cannot
be completed by adding process data, mask I/O, trust policy, or flow lifecycle
ownership to PhysicalDesignEngine.

| Former ID | Owner | Required evidence |
|---|---|---|
| PHY-1 | Physical qualification workflow | Actual OpenROAD/PDK runs retaining exact executable, process, PDK, RC, Liberty, corner, input/output, health and independent oracle identities for ToolQualification reconstruction. |
| PHY-W3 | Production Xcircuite/DesignFlowKernel workflow | A real-backend run covering raw evidence, failure, review, approval, resume, downstream signoff handoff, and immutable artifact verification. |

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
