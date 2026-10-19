# Sky130 selected placement-cost sources

These fixture files preserve exact unmodified byte ranges from the installed Sky130A source views. `selection-report.json` binds original and selected digests and source ranges. `original-technology.raw` retains the complete original technology view, including excluded laws. The complete selected inv_1 macro retains all signal/power/well PORT and OBS geometry. The selected Liberty retains its original library header, units, operating condition, templates and full inv_1 block.

This is a characterization/pre-route ground-capacitance cost fixture with limited manufacturing coverage. It is not evidence that the original full source parses, that excluded antenna/current-density/enclosed-area laws are implemented, or that placement is production legal. No routed metal or vias are constructed. The original rule-bearing technology input remains an explicit failure test. Original source paths in the report identify the acquisition origin; byte identity does not depend on those paths remaining available.

Behavioral owner: [CharacterizedPlacementTests](../../../Tests/PhysicalDesignEngineTests/CharacterizedPlacementTests.swift). The actual API and built CLI compare exact candidate STA results, and changing the critical SDC endpoint reverses the selected pose while preserving total wirelength. Native timing and production claims remain blocked.
