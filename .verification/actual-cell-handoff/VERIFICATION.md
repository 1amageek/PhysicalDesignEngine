# Checked actual-cell physical connectivity handoff

Swift 6.4.0 / macOS 27 Native: 130 tests in 16 suites pass under a 300-second
process timeout (10.606 seconds including build). New tests execute exact source,
actual-cell mapping, immutable save, checked source/RUP reload and physical logical
connectivity admission. Wrong master, pin name, rewiring, incomplete correspondence,
resource exhaustion and missing physical tie insertion fail. Complete pin/net
membership is bounded before allocation. The checked output retains immutable
input values and has no public initializer or decoder.

This host module is separate from PhysicalDesignCore and introduces no Runtime
backedge into Core. Core explicitly adopts host serialization for existing logical
reference DTOs. No shared state or target-dependent isolation was introduced.
Geometry, exact LEF/PDK view admission, DRC/LVS, timing and release qualification
remain their existing owners; this logical check does not certify them.
