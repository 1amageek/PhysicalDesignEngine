# Master Geometry

## Purpose and Scope

Resolve exact LEF master dimensions before canonical cell construction.
Parent: [PhysicalDesignCore](../DESIGN.md). No children.

## Responsibilities and Boundaries

Own master-name uniqueness, required SIZE and exact micron-to-DBU dimensions.
The DEF adapter owns placement syntax and explicit geometry-smoke extensions.
ProcessInputs owns selected source identity. Pin access, site legality, orientation
transforms and via geometry are separate pending process geometry responsibilities.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent / used by | Canonical cell geometry and DEF intake | Construction boundary | Missing dimensions cannot become a successful cell |
| [ProcessInputs](../ProcessInputs/DESIGN.md) | depends on | Exact integer DBU conversion and selected LEF documents | Native source projection | Caller retains exact source identities |
| [LEF](../../../../swift-mask-data/Sources/LEF/DESIGN.md) | depends on | LEFMacroDef SIZE | Standard-owned master definition | Duplicate names are ambiguous even with equal dimensions |

## Architecture

```text
Selected LEF masters -> exact name lookup -> required SIZE -> exact DBU
    -> DEF component dimensions -> canonical snapshot validation
```

## Contracts and Invariants

- Canonical Cell construction requires explicit width and height. No constructor
  or parser supplies fabricated default dimensions.
- A supplied library is authoritative: every component master resolves exactly
  once, with finite positive width/height representable on the requested DBU grid.
- Explicit DEF dimension extensions must agree with a supplied LEF master.
  Without a library, complete explicit dimensions allow only unqualified geometry
  interchange; absent or partial dimensions fail before snapshot publication.
- The current DEF adapter supports N orientation only. Other orientations fail
  explicitly until process transforms are implemented and behaviorally verified.

## Runtime Flows

DEF units -> component master and explicit extensions -> dimensions -> canonical
Cell. Failure returns structured DEF diagnostics with component and source line.
Native execution supplies admitted cell views to this adapter; cell-qualified
mutation remains blocked until the remaining process geometry contracts close.

## State, Ownership, and Lifecycle

One parse owns immutable grouped master values. No shared state, cache or pointer
is introduced. Lookups are bounded by one master-name group per component.

## Failure, Concurrency, and Constraints

Ambiguous/missing masters, missing SIZE, nonfinite/sub-DBU dimensions and conflicting
extensions produce no snapshot. Exact conversion admits only one ULP of binary
multiplication noise and rejects values outside the precise integer range.

## Verification and Change Impact

Master geometry regression tests exercise successful standard master resolution,
explicit smoke dimensions, missing/ambiguous masters, partial/conflicting extensions
and off-grid dimensions through the public DEF API. Recheck source-bound native
intake and standard interchange consumers when dimension or parser contracts change.
