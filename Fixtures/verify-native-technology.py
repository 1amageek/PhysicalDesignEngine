"""Verify synthetic native PDK/LEF execution through the built CLI."""
import copy
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def verify(executable):
    with tempfile.TemporaryDirectory(prefix="native-technology-cli-") as directory:
        root = Path(directory)
        shutil.copytree(Path(__file__).resolve().parent, root / "Fixtures")
        template = json.loads((root / "Fixtures/positive-technology-floorplan-request.json").read_text())

        def read(binding):
            data = root.joinpath(*binding["availability"]["relativePath"]).read_bytes()
            identity = (b"CircuiteArtifactContent\0" + struct.pack(">HH", 1, 6) + b"sha256"
                        + struct.pack(">H", 32) + hashlib.sha256(data).digest() + struct.pack(">Q", len(data)))
            assert bytes.fromhex(binding["reference"]["id"]) == identity, binding["logicalID"]
            return data

        def execute(request, status="completed", code=None):
            path = root / (request["runID"] + ".json")
            path.write_text(json.dumps(request))
            process = subprocess.run([str(executable), "--request", str(path), "--project-root", str(root)],
                                     capture_output=True, timeout=30)
            result = json.loads(process.stdout)
            assert result["status"] == status, result.get("diagnostics")
            assert (process.returncode == 0) == (status == "completed")
            assert result["payload"]["claims"]["production"] == "blocked"
            if status == "blocked":
                assert not result.get("artifacts") and not result.get("artifactBindings")
                assert any(item["code"] == code for item in result["diagnostics"]), result["diagnostics"]
                assert not (root / "runs" / request["runID"]).exists()
                return None, None, None
            bindings = result["artifactBindings"]
            assert len(bindings) == 4
            for binding in bindings:
                read(binding)
            binding = next(item for item in bindings if item["logicalID"].endswith("/revision.json"))
            manifest_binding = next(item for item in bindings if item["logicalID"].endswith("/run-manifest.json"))
            manifest = json.loads(read(manifest_binding))
            assert template["pdk"]["digest"] == manifest["pdk"]["digest"]
            technology = [b for b in template["inputBindings"] if b["reference"]["descriptor"]["format"] == "lef"]
            assert manifest.get("technologyLEFs") == technology, "Technology input availability was not retained"
            return binding, json.loads(read(binding)), manifest

        for binding in template["inputBindings"]:
            read(binding)
        request = copy.deepcopy(template)
        request["runID"] = "verify-technology-floorplan"
        binding, snapshot, manifest = execute(request)
        tracks = snapshot["implementationState"]["tracks"]
        assert [(t["layer"], t["direction"], t["origin"], t["spacing"], t["count"]) for t in tracks] == [
            (2, "horizontal", 10100, 200, 400), (3, "vertical", 10100, 400, 400)]
        routed = None
        for stage in ["global_routing", "detailed_routing"]:
            request = copy.deepcopy(template)
            request.update(stage=stage, runID="verify-technology-" + stage, initialSnapshot=None)
            request["inputLayout"] = dict(layoutArtifact=binding, topCell=snapshot["topCell"],
                                           layoutDigest=hashlib.sha256(read(binding)).hexdigest())
            request["inputBindings"] = [b for b in request["inputBindings"] if b["reference"]["descriptor"]["format"] != "lef"] + manifest["technologyLEFs"]
            request["inputBindings"].append(binding)
            request["inputs"].append(binding["reference"])
            binding, snapshot, manifest = execute(request)
            assert snapshot["implementationState"]["tracks"] == tracks
            for route in snapshot["routes"]:
                for segment in route["segments"]:
                    horizontal = segment["y1"] == segment["y2"]
                    track = tracks[0 if horizontal else 1]
                    coordinate = segment["y1" if horizontal else "x1"]
                    assert segment["layer"] == track["layer"]
                    assert coordinate >= track["origin"]
                    assert (coordinate - track["origin"]) % track["spacing"] == 0
                    assert (coordinate - track["origin"]) // track["spacing"] < track["count"]
            assert len(snapshot["routes"]) == 1 and len(snapshot["vias"]) == 1
            assert snapshot["vias"][0]["lowerLayer"] == 2 and snapshot["vias"][0]["upperLayer"] == 3
            if routed is not None:
                assert (snapshot["routes"], snapshot["vias"]) == routed
            routed = snapshot["routes"], snapshot["vias"]

        request = copy.deepcopy(template)
        request.update(stage="global_routing", runID="verify-off-grid", initialSnapshot=copy.deepcopy(snapshot))
        request["initialSnapshot"]["pins"][0]["y"] += 1
        execute(request, "blocked", "routing_track_grid_conflict")
        request = copy.deepcopy(template)
        request["runID"] = "verify-wrong-process"
        request["pdk"]["processID"] = "another-process"
        execute(request, "blocked", "physical_technology_invalid")
        request = copy.deepcopy(template)
        request.update(runID="verify-omitted-technology", initialSnapshot=snapshot)
        technology = next(b for b in request["inputBindings"] if b["reference"]["descriptor"]["format"] == "lef")
        request["inputBindings"].remove(technology)
        request["inputs"].remove(technology["reference"])
        execute(request, "blocked", "physical_technology_invalid")
        technology_path = root.joinpath(*technology["availability"]["relativePath"])
        original = technology_path.read_bytes()
        try:
            technology_path.write_bytes(original + b"# changed bytes\n")
            request = copy.deepcopy(template)
            request["runID"] = "verify-tampered-technology"
            execute(request, "blocked", "physical_input_artifact_invalid")
        finally:
            technology_path.write_bytes(original)
        request = copy.deepcopy(template)
        request.update(runID="verify-native-production", executionIntent="productionImplementation")
        execute(request, "blocked", "native_production_implementation_unsupported")
        print("PASS: exact PDK/LEF -> floorplan -> retained JSON -> global -> detailed; output identities, grids and vias verified; source/grid/production failures emitted no artifacts.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 Fixtures/verify-native-technology.py <built-physical-design-path>")
    verify(Path(sys.argv[1]).resolve())
