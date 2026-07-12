import Foundation

public enum PhysicalECOAction: String, Sendable, Hashable, Codable, CaseIterable {
    case resizeCell = "resize_cell"
    case moveCell = "move_cell"
    case bufferInsertion = "buffer_insertion"
    case rerouteNet = "reroute_net"
    case addBlockage = "add_blockage"
}
