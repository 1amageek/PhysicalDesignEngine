# PhysicalDesignEngine Implementation Plan

## Delivered foundation

1. Direct CircuiteFoundation `Engine` conformance and Foundation result/evidence types
2. Immutable artifact store with digest/byte verification and symlink-safe workspace containment
3. Canonical JSON snapshot and supported DEF parser/writer
4. Deterministic native geometry for declared stages
5. Reviewable design diff, implementation proof, and run manifest
6. Geometry/timing/production intent and claim separation
7. PDK/RC/Liberty/corner-bound CTS timing model
8. ToolQualification process-evidence consumer with physical oracle cross-binding
9. Foreign mask-data encoder protocol without self-qualification

## Native completion gate

The native backend is complete only for its declared geometry-smoke scope. It must:

- remain deterministic for the same canonical inputs and seed;
- keep DBU geometry separate from PS timing;
- block timing when characterization is absent;
- block every native production-eligible request;
- emit immutable artifacts and structured diagnostics;
- remain independently executable through typed API and CLI.

## Production backend gate

A future production backend may be composed only when all of these are retained and verified:

| Evidence | Owner |
|---|---|
| Tool/oracle executable, process profile, PDK, rule deck, corpus, oracle, and health evidence | ToolQualification |
| Physical stage/corner/RC/Liberty correlation and separate backend/oracle outputs | PhysicalDesignEngine domain evidence |
| Flow transition, human approval, resume, release policy | DesignFlowKernel |
| Workspace persistence | Xcircuite |

No PhysicalDesignEngine type may issue its own production qualification or elevate a native result from a caller-provided boolean/string.

## Remaining implementation work

- Add a real placement/routing backend as an independent protocol implementation.
- Retain process-specific physical corpus, oracle and health result artifacts produced by actual tools for ToolQualification reconstruction.
- Implement concrete GDSII/OASIS encoders through a mask-data library and qualify those implementations in ToolQualification.
- Integrate DRC/LVS/PEX/Timing feedback through the host flow without treating native proxy checks as signoff.
- Add end-to-end Xcircuite/DesignFlowKernel fixtures once the external backend exists.

## Verification

Every change requires timeout-bounded Xcode build/test, structured negative tests, immutable artifact verification, updated capability documentation, and explicit production-blocking behavior when evidence is incomplete.
