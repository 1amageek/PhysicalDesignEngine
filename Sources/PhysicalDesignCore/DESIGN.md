# PhysicalDesignCore

## Purpose and Scope

PhysicalDesignCore is the package's state, executor, mutation and persistence module.
Parent: [package design](../../DESIGN.md). Child:
[TechnologyConstraints](TechnologyConstraints/DESIGN.md).

## Responsibilities and Boundaries

The module owns native request execution and canonical snapshots. PDKKit owns
process manifest semantics; swift-mask-data owns standard parsing. Host approval,
release and database persistence remain outside this module.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Execution and artifact invariants | Public stage behavior | Production remains blocked |
| [TechnologyConstraints](TechnologyConstraints/DESIGN.md) | child | Verified snapshot preparation | PDK/LEF to native tracks | No process qualification claim |
| [PDKKit](../../../PDKKit/DESIGN.md) | depends on | PDKCore manifest values | Process identity and layer mappings | Use the fixed package implementation |
| [swift-mask-data](../../../swift-mask-data/DESIGN.md) | depends on | LEF reader/tokenizer | Standard view parsing | Reject projections that discard needed constraints |

## Architecture

```text
NativePhysicalDesignExecutor -> TechnologyConstraints -> prepared snapshot
    -> PhysicalDesignNativeMutationEngine -> immutable artifact store
```

## Contracts and Invariants

The package design owns stage/result and artifact contracts. Grid admission is the
planned R9 change: with explicit tracks,
every generated signal/ECO/clock segment must lie on at least one declared track
of the same layer and direction: coordinate minus origin is nonnegative, divisible
by spacing and less than count in track units. Checked subtraction rejects overflow.
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
