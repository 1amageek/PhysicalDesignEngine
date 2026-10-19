protocol PhysicalDesignPlacementAllocating: Sendable {
    func allocate(_ input: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
        processGeometry: PhysicalDesignProcessGeometry?, checkpoint: (@Sendable () throws -> Void)?) throws -> PhysicalDesignPlacementAllocation
}
