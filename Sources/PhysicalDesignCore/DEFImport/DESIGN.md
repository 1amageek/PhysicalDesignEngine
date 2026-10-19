# DEFImport

## Purpose and Scope

Invocation-local native DEF input parsing. Parent: [PhysicalDesignCore](../DESIGN.md).
No children. The existing public `PhysicalDesignDEFParser.parse` API and source-bound
internal adapter remain in PhysicalDesignCore; this directory owns their implementation.

## Responsibilities and Boundaries

The parser owns its bounded DEF grammar, canonical conversion and structured diagnostics.
The shared lexer remains module infrastructure. LEF/master/process geometry is admitted
by the existing owners. The DEF writer and EDA semantic-loss report remain separate owners.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent | Native snapshot and artifact contracts | Execution consumes admitted input | No process qualification |
| [MasterGeometry](../MasterGeometry/DESIGN.md) | depends on | Exact master SIZE | Cell dimension authority | Declarations supply no geometry |
| [DEFMapping](../../../../EDAInteroperability/Sources/OpenROADInteroperability/DEFMapping/DESIGN.md) | used by | Public parser and diagnostics | Strict reimport of actual OpenROAD bytes | Semantic-loss policy is unchanged |

## Architecture

```text
DEF bytes -> shared lexer -> invocation-local parser state -> canonical snapshot
                                      -> structured diagnostics -> refusal
```

## Contracts and Invariants

The optional uncounted `PROPERTYDEFINITIONS` section ends with `END PROPERTYDEFINITIONS`.
Only `COMPONENT XCI_CELL_WIDTH INTEGER ;` and `COMPONENT XCI_CELL_HEIGHT INTEGER ;`
are admitted, with the existing case-insensitive reserved-name convention. Each may
appear once; a repeated section or declaration is an error. Unknown property names,
changed owner/type, defaults, ranges, extra fields and incomplete section delimiters
produce error diagnostics with the declaration section as authority. No declaration
creates a value or changes interpretation of a per-instance property.

Cells require complete explicit dimensions or admitted exact LEF master dimensions.
Missing/contradictory dimensions still refuse; explicit dimensions cannot replace LEF
SIZE. Existing inputs without a declaration section remain accepted under their
previous geometry and process admission. Public parse output and snapshot/request
schemas remain unchanged; parser provenance is version 3.1.0 for the admitted declaration
grammar. No external-output normalization or codec duplication occurs.

## State, Ownership, and Lifecycle

Tokens, section/declaration membership and diagnostics belong to one parse invocation.
No state survives or is shared across calls. Returned values own canonical data.

## Failure, Concurrency, and Constraints

Any declaration error prevents snapshot publication. Parsing consumes the existing
bounded input token buffer; declaration checking is linear and stores at most two
reserved names. No I/O, retry or asynchronous state is introduced. Unknown grammar
is refused rather than skipped into apparent semantic completeness.

## Verification and Change Impact

[DEFPropertyDefinitionTests](../../../Tests/PhysicalDesignEngineTests/DEFPropertyDefinitionTests.swift)
uses the original 399-byte actual OpenROAD output through the public parser and checks
exact dimensions/placement plus absence of semantic-loss diagnostics. Counterexamples
assert typed unknown/repeated/changed/default/range/delimiter refusal and that declarations
cannot fabricate dimensions. Existing MasterGeometryTests retains master authority.
The direct EDA consumer must recheck strict genuine reimport after adopting this commit.
The unchanged native repair API/CLI/atomic publication compatibility subset checks the
new exact dependency floor; prior stage proofs remain scoped to unchanged semantics.
