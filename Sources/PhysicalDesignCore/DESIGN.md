# PhysicalDesignCore

## Purpose and Scope

PhysicalDesignCore is the package's state, executor, mutation and persistence module.
Parent: [package design](../../DESIGN.md). Child:
[TechnologyConstraints](TechnologyConstraints/DESIGN.md),
[ProcessInputs](ProcessInputs/DESIGN.md),
[MasterGeometry](MasterGeometry/DESIGN.md), and
[ProcessGeometry](ProcessGeometry/DESIGN.md).

## Responsibilities and Boundaries

The module owns native request execution and canonical snapshots. PDKKit owns
process manifest semantics; swift-mask-data owns standard parsing. Host approval,
release and database persistence remain outside this module.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Execution and artifact invariants | Public stage behavior | Production remains blocked |
| [TechnologyConstraints](TechnologyConstraints/DESIGN.md) | child | Verified snapshot preparation | PDK/LEF to native tracks | No process qualification claim |
| [ProcessGeometry](ProcessGeometry/DESIGN.md) | child | Exact mapped cell/pin/site/via shapes | Native process projection | Projection alone does not prove native closure |
| [MasterGeometry](MasterGeometry/DESIGN.md) | child | Required exact LEF master dimensions | Canonical cell construction | No fabricated dimensions |
| [ProcessInputs](ProcessInputs/DESIGN.md) | child | Explicit asset-ID-bound standard views | Shared exact physical source intake | Input identity and manifest role are validated before projection |
| [PDKKit](../../../PDKKit/DESIGN.md) | depends on | PDKCore manifest values | Process identity and layer mappings | Use the fixed package implementation |
| [swift-mask-data](../../../swift-mask-data/DESIGN.md) | depends on | LEF reader and typed axis values | Standard view parsing | Common codec owns loss admission; native profiles own rule support |

## Architecture

```text
NativePhysicalDesignExecutor -> ProcessInputs -> TechnologyConstraints -> mutation -> artifacts
    -> MasterGeometry during source-bound DEF decode
ProcessInputs -> ProcessGeometry -> canonical input admission -> mutation -> output admission
    -> JSON resume reference + bounded DEF interchange + diff/manifest
```

## Contracts and Invariants

Canonical snapshot schema 2 retains standard cell orientation, source-bound process
references, pin layer, row site and fixed-via master. ProcessGeometry admits exact
source geometry before and after mutation. Public bare mutation cannot bypass intake.
The native result's physical reference is JSON for lossless same-source resume; DEF
remains the separate bounded standard interchange artifact.

The package design owns stage/result and artifact contracts. With explicit tracks,
every generated signal/ECO/clock segment must lie on at least one declared track
of the same layer and direction: coordinate minus origin is nonnegative, divisible
by spacing and less than count in track units. Checked subtraction rejects overflow.
Canonical cells require explicit dimensions. The DEF standard-format adapter
resolves admitted LEF masters or requires complete explicit smoke dimensions;
missing or contradictory geometry fails before snapshot publication.
The no-track geometry-smoke convention remains an explicitly incomplete path.
Off-grid pin access is unsupported and blocks; it is not rounded or snapped.

## State, Ownership, and Lifecycle

Technology and mutation values are invocation-local, Sendable values. The store
owns input byte verification. No shared mutable state or conditional isolation is added.

## Failure, Concurrency, and Constraints

Failed preparation or grid validation produces diagnostics and no successful revision.
Routing retains the existing cancellation and single-bend algorithm boundaries.

## Verification and Change Impact

[NativeExecutionTests](../../Tests/PhysicalDesignEngineTests/NativeExecutionTests.swift)
and the component tests exercise retained bytes and stage failures. Grid changes
affect signal routing, ECO rerouting and CTS. Technology changes affect all stages
that receive technology LEF. Verify these paths before package/CLI integration.
