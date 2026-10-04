"""Independent generalized-eigenmode oracle of the actual retained PEX RC operator.

No CoreSpice call or timestep reuse. The source is the fixture's explicit 0.1 ns
linear ramp followed by a hold. Floating other conductors are the declared quiet
reference boundary, while internal coupling remains in the capacitance matrix.
"""
import json
import sys
import time
import numpy as np
from scipy.linalg import eigh

started = time.monotonic()
source = json.load(open(sys.argv[1], encoding="utf-8"))
resistors = source["resistors"] + source["contacts"]
root, sink = source["sourceNode"], source["sinkNode"]
adjacency = {}
for element in resistors:
    adjacency.setdefault(element["a"], set()).add(element["b"])
    adjacency.setdefault(element["b"], set()).add(element["a"])
active, queue = {root}, [root]
for node in queue:
    for neighbour in adjacency.get(node, ()):
        if neighbour not in active:
            active.add(neighbour)
            queue.append(neighbour)
assert sink in active
free = sorted(active - {root})
indices = {node: index for index, node in enumerate(free)}
g = np.zeros((len(free), len(free)))
c = np.zeros_like(g)
drive = np.zeros(len(free))
for element in resistors:
    a, b, conductance = element["a"], element["b"], 1 / element["value"]
    if a not in active or b not in active:
        continue
    for node, other in [(a, b), (b, a)]:
        if node == root:
            continue
        i = indices[node]
        g[i, i] += conductance
        if other == root:
            drive[i] += conductance
        else:
            g[i, indices[other]] -= conductance
for element in source["capacitors"]:
    a, b, value = element["a"], element.get("b"), element["value"]
    for node, other in [(a, b), (b, a)]:
        if node not in indices:
            continue
        i = indices[node]
        c[i, i] += value
        if other in indices:
            c[i, indices[other]] -= value
c[indices[sink], indices[sink]] += source["inputCapacitance"]
eigenvalues, eigenvectors = eigh(g, c)
assert np.all(eigenvalues > 0)
coefficients = eigenvectors[indices[sink], :] * np.einsum("ij,i->j", eigenvectors, drive) / eigenvalues
assert np.all(np.isfinite(coefficients))
assert abs(coefficients.sum() - 1) < 1e-8
ramp_duration = 1e-10

def rise(times):
    columns = np.asarray(times, dtype=float)[:, None]
    during = columns / ramp_duration + np.expm1(-columns * eigenvalues) / (eigenvalues * ramp_duration)
    after = 1 - np.exp(-np.maximum(columns - ramp_duration, 0) * eigenvalues) * (-np.expm1(-ramp_duration * eigenvalues)) / (eigenvalues * ramp_duration)
    output = np.einsum("ij,j->i", np.where(columns <= ramp_duration, during, after), coefficients)
    assert np.all(np.isfinite(output))
    return output

def crossing(level):
    lower, upper = 0.0, 5e-9
    for _ in range(70):
        midpoint = (lower + upper) / 2
        if rise([midpoint])[0] < level:
            lower = midpoint
        else:
            upper = midpoint
    return (lower + upper) / 2

oracle = {str(level): crossing(level) for level in (0.2, 0.5, 0.8)}
waveform_error, crossing_error = 0.0, 0.0
for observation in source["evidence"]["sinks"]:
    times = [point["time"] for point in observation["waveform"]]
    expected = rise(times)
    if observation["sinkEdge"] == "fall":
        expected = 1 - expected
    actual = np.array([point["voltage"] for point in observation["waveform"]])
    waveform_error = max(waveform_error, float(np.max(np.abs(actual - expected))))
    crossing_error = max(crossing_error, abs(observation["arrivalSeconds"] - oracle["0.5"]),
                         abs(observation["slewSeconds"] - (oracle["0.8"] - oracle["0.2"])))
assert waveform_error < 5e-4, waveform_error
assert crossing_error < 1e-12, crossing_error
print(json.dumps({"method": "independent generalized symmetric RC eigenmodes and exact ramp convolution",
    "stateDimension": len(free), "oracleCrossingsSeconds": oracle,
    "maximumWaveformAbsoluteErrorVolts": waveform_error,
    "maximumArrivalOrSlewAbsoluteErrorSeconds": crossing_error,
    "elapsedSeconds": time.monotonic() - started, "physicalSignoffQualification": "unqualified"}, indent=2))
