protocol PhysicalDesignPlacementAllocating: Sendable {
    func allocate(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
        processGeometry: PhysicalDesignProcessGeometry?) throws -> PhysicalDesignPlacementAllocation
}
