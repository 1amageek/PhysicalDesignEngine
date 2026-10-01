# PhysicalDesignEngine Fixtures

The schema-6 positive request exercises native geometry-smoke floorplanning and
emits verified JSON, DEF, design diff and manifest artifacts. The returned physical
reference identifies schema-2 JSON as the lossless resume authority; DEF is the
separate standard interchange artifact. The retained Verilog,
SDC and synthetic process metadata in `inputs/` have exact byte-count/digest-bound
identities. They are regression inputs, not foundry PDK or timing qualification.
`positive-interchange.def` covers the supported DEF parser subset and requires an
explicit `INV_X1` LEF master (1 by 1 micron); DEF alone does not define cell size.

| Request | Expected result |
|---|---|
| `positive-floorplan-request.json` | Exit 0, completed, four immutable artifacts; production claim blocked |
| `positive-technology-floorplan-request.json` | Exit 0, exact synthetic PDK/LEF binding, horizontal M2 / vertical M3 tracks; production blocked |
| `negative-missing-snapshot-request.json` | Exit 1, blocked, `physical_snapshot_missing`, no successful artifacts |
| `negative-native-production-request.json` | Exit 1, blocked, `native_production_implementation_unsupported` |

Run from the package root. Each command is bounded by a timeout; use a fresh project
root for each run. Copy `Fixtures/` into that root before executing a request so
input availability paths remain valid.

The technology fixture uses alias-mapped layers, scalar micron constraints and
global grid offsets. The PDK has no device/corner qualification and cannot support
production claims. Its request activates technology through input-role `technology`
bindings with format `lef`; later stages retain those exact bindings. The complete
subset/rejection policy is in
[TechnologyConstraints](../Sources/PhysicalDesignCore/TechnologyConstraints/DESIGN.md).

```bash
../scripts/swift-test-timeout.sh 30 --jobs 4 --filter PhysicalDesignCLIProcessTests
```

`swift test` builds the CLI and test products together. The tests find the CLI
relative to their own resource bundle's products directory, including when run individually. Separate CLI
builds and `BUILT_PRODUCTS_DIR` are unnecessary. After changes converge, run the
package and technology handoff checks once:

```bash
../scripts/swift-test-timeout.sh 30 --jobs 4
python3 Fixtures/verify-native-technology.py "$(swift build --show-bin-path)/physical-design"
```

Use `--filter <SuiteOrTestName>` for the changed behavior while iterating. Use
`--skip-build` only for another filter or timing measurement on the same already
built source/configuration snapshot; rebuild after any source or fixture edit.
The 30-second timeout covers preparation and tests. A first dependency build can
use 120 seconds when needed; retain the same checks.

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

`verify-native-technology.py` uses an isolated temporary root and 30-second timeouts
per CLI call. It replays saved manifest technology availability through floorplan,
global and detailed routing, verifies all input/output identities and preserves
routes/vias. Off-grid access, wrong process, omitted/tampered technology and native
production intent must fail without artifacts. This is synthetic geometry evidence.

For `resize_cell`, select `configuration.ecoTargetCellID` and
`configuration.ecoReplacementMaster` with exact cell-role LEF process assets.
The replacement retains the instance pose and pin/net IDs, uses the selected
oriented SIZE, and rebuilds connected pins from its declared PORT geometry.
Missing sources/master, changed physical port names/directions/uses, incompatible
site/symmetry or illegal placement fail without a revision. Source-free geometry
smoke cannot resize a cell by fabricating dimensions or a master name.
This operation does not prove functional equivalence or timing improvement.
Run the source-bound API regressions with
`../scripts/swift-test-timeout.sh 120 --jobs 4 --filter exactReplacement`.

Process-bound native layer transitions use a unique DEFAULT fixed LEF via for
each declared routing-layer pair, including pin access layers at path endpoints.
Explicit named vias preserve their source identity during redundant insertion.
The current center-joined profile rejects offset routing footprints and any full
translated footprint outside the construction core. It does not establish
process cut/enclosure DRC or legal width-aware pin access.
Run `../scripts/swift-test-timeout.sh 120 --jobs 4 --filter 'constructedFixedVias|viaFootprintAuthority'`
for these source-bound regressions.
