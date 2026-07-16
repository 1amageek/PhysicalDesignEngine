import Foundation

public struct PhysicalDesignCapabilityClaims: Sendable, Hashable, Codable {
    public var geometry: PhysicalDesignClaimStatus
    public var timing: PhysicalDesignClaimStatus
    public var production: PhysicalDesignClaimStatus

    public init(
        geometry: PhysicalDesignClaimStatus,
        timing: PhysicalDesignClaimStatus,
        production: PhysicalDesignClaimStatus
    ) {
        self.geometry = geometry
        self.timing = timing
        self.production = production
    }

    public static let blocked = Self(
        geometry: .blocked,
        timing: .blocked,
        production: .blocked
    )
}
