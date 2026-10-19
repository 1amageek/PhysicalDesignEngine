# Selected Sky130 actual-cell CTS fixture

Exact unchanged byte ranges from the installed Sky130A views preserve three complete cell macros, their actual PORT/OBS geometry, full selected Liberty cells and templates, and one fixed via. The selection report binds original/selected SHA-256 identities and byte ranges and lists excluded manufacturing laws. The complete original technology source remains retained.

These sources exercise primary-clock Native CTS construction and actual-cell functional proof. The electrical RC coefficients and electrode boundary conditions are explicit analytical test assumptions, not Sky130 calibration or physical signoff. No full raw PDK acceptance, antenna, DRC, LVS, post-route timing, production qualification or release is established. Well regions remain in the actual source and snapshot; clock interconnect projection treats only declared metal/cut layers as interconnect conductors.

The fixture manifest projects its functional standard-cell inventory from the checked Liberty library and binds it to the selected LEF/Liberty views, as specified by the [Handoff design](../../../../../Sources/PhysicalDesignLogicHandoff/DESIGN.md#native-cts-candidate-consumption). It adds no transistor, SPICE or extraction-recognition model.

The same design owns the 140 DBU caller spacing floor, combined with each actual source spacing by maximum (li1 170 DBU, met1 140 DBU), and separated manual top-port placement. The primary clock PORT is centered at the retained li1 track x = 16790 DBU, and all other top PORTs at x = 17710 DBU. The fixture checks every actual top PORT contains the full source-width on-track wire cap. Original stricter/overlapping-clearance configurations remain explicit negative profiles; all selected source bytes and rules remain unchanged.

The current request explicitly selects per-layer source-default routing widths. Its uniform-width negative profile retains the scalar override and must fail; the shared DEF reader verifies saved route geometry without changing either original layer WIDTH.
