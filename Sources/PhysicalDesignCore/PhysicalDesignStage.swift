import Foundation

public enum PhysicalDesignStage: String, Sendable, Hashable, Codable, CaseIterable {
    case floorplan
    case powerPlanning = "power_planning"
    case placement
    case clockTreeSynthesis = "clock_tree_synthesis"
    case globalRouting = "global_routing"
    case detailedRouting = "detailed_routing"
    case timingECO = "timing_eco"
    case drcRepair = "drc_repair"
    case antennaRepair = "antenna_repair"
    case fillInsertion = "fill_insertion"
    case redundantViaInsertion = "redundant_via_insertion"
    case hotspotRepair = "hotspot_repair"

    public var engineID: String {
        "physical-design.\(rawValue)"
    }

    public var isP0: Bool {
        switch self {
        case .floorplan, .powerPlanning, .placement, .clockTreeSynthesis,
             .globalRouting, .detailedRouting, .timingECO, .drcRepair:
            return true
        case .antennaRepair, .fillInsertion, .redundantViaInsertion, .hotspotRepair:
            return false
        }
    }
}
