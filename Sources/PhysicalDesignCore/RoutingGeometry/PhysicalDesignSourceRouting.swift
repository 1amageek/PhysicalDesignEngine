protocol PhysicalDesignSourceRouting: Sendable {
    func route(_ snapshot: PhysicalDesignSnapshot, configuration: PhysicalDesignConfiguration,
        mode: String, onlyNetID: String?, geometry: PhysicalDesignProcessGeometry) throws -> PhysicalDesignSourceRouter.Result
}
