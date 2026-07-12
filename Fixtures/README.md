# PhysicalDesignEngine fixtures

The positive request is a deterministic canonical-snapshot floorplan run. It emits a revision, DEF handoff, design diff and provenance manifest. The negative request deliberately omits the canonical physical snapshot and must return a structured `blocked` result with `physical_snapshot_missing`.

Run them from this package with:

```bash
swift run physical-design --request Fixtures/positive-floorplan-request.json --project-root .
swift run physical-design --request Fixtures/negative-missing-snapshot-request.json --project-root .
```
