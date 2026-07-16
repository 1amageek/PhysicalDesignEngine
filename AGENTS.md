# PhysicalDesignEngine Implementation Instructions

## Goal

Implement floorplan, placement, cts, routing, eco, antenna repair and dfm mutation contracts.

## Required boundaries

- Keep public interfaces protocol-first.
- Use one primary type per Swift file.
- Keep code, comments and documentation comments in English.
- Use typed errors and never use `try?`.
- Do not add `@unchecked Sendable`, `DispatchQueue` or `EventLoopFuture`.
- Use actor only for ordered or suspending state; use Mutex for short in-memory critical sections.
- Do not import Xcircuite or circuit-studio.
- Preserve the direct Foundation request/result and artifact provenance contract.
- Treat unavailable semantics as blocked, not passed.
- Require native and external implementations to conform directly to the same stage protocol.
- Keep tool qualification and production eligibility in ToolQualification and host flow policy.
- Keep geometry DBU values separate from characterized timing PS values.

## Before implementation

Read README.md, DESIGN.md, INTERFACES.md and IMPLEMENTATION_PLAN.md completely.

## Definition of done

Build, timeout-bounded tests, fixtures, structured diagnostics, CLI reproducibility, immutable artifact verification, and honest qualification scope are all required.
