# PhysicalDesignEngine Fixtures

The schema-5 positive request exercises native geometry-smoke floorplanning and
emits verified JSON, DEF, design diff and manifest artifacts. The retained Verilog,
SDC and synthetic process metadata in `inputs/` have exact byte-count/digest-bound
identities. They are regression inputs, not foundry PDK or timing qualification.
`positive-interchange.def` covers the supported DEF parser subset.

| Request | Expected result |
|---|---|
| `positive-floorplan-request.json` | Exit 0, completed, four immutable artifacts; production claim blocked |
| `negative-missing-snapshot-request.json` | Exit 1, blocked, `physical_snapshot_missing`, no successful artifacts |
| `negative-native-production-request.json` | Exit 1, blocked, `native_production_implementation_unsupported` |

Run from the package root. Each command is bounded by a timeout; use a fresh project
root for each run. Copy `Fixtures/` into that root before executing a request so
input availability paths remain valid.

```bash
swift build --product physical-design --jobs 4
BUILT_PRODUCTS_DIR="$(swift build --show-bin-path)" ../scripts/swift-test-timeout.sh 120 --jobs 4
```

For direct CLI execution, set `fixture_run_root` to a fresh directory containing a
copy of `Fixtures/`, then execute the already built product:

```bash
python3 - "$fixture_run_root" <<'PYTHON'
import subprocess
import sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
executable = Path(subprocess.check_output(
    ["swift", "build", "--show-bin-path"], text=True
).strip()) / "physical-design"
subprocess.run([
    str(executable), "--request", str(root / "Fixtures/positive-floorplan-request.json"),
    "--project-root", str(root)
], timeout=30, check=True)
PYTHON
```

CLI process regressions copy these exact fixtures to isolated temporary roots,
verify every input and successful output from bytes, and check the documented
failure diagnostics. The obsolete OpenROAD-unavailable fixture was removed because
this package has no external execution branch.
