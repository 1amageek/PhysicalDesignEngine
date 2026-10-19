public struct PhysicalDesignRoutingSourceAdoptionInput: Sendable {
    public struct Limits: Sendable {
        public let maximumCombinedInputBytes: Int
        public let maximumSourceAssets: Int
        public let maximumSourceEntries: Int

        public init(maximumCombinedInputBytes: Int, maximumSourceAssets: Int, maximumSourceEntries: Int) {
            self.maximumCombinedInputBytes = maximumCombinedInputBytes
            self.maximumSourceAssets = maximumSourceAssets
            self.maximumSourceEntries = maximumSourceEntries
        }
    }

    public let parent: PhysicalDesignReference
    public let oldRequest: PhysicalDesignRequest
    public let newRequest: PhysicalDesignRequest
    public let limits: Limits

    public init(parent: PhysicalDesignReference, oldRequest: PhysicalDesignRequest,
                newRequest: PhysicalDesignRequest, limits: Limits) {
        self.parent = parent; self.oldRequest = oldRequest; self.newRequest = newRequest; self.limits = limits
    }
}
