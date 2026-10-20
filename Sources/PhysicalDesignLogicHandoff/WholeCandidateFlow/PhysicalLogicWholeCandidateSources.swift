import CoreSpiceIO

/// Keeps newly constructed catalog slots alive with every retained checked-source preparation.
internal struct PhysicalLogicWholeCandidateSources: SPICEExactSourceProviding {
    let baseRoot: SPICECheckedSource
    let root: SPICECheckedSource
    let parent: any SPICEExactSourceProviding
    let catalogStorage: SPICESourceStorageReservation
    let constructionStorage: SPICESourceStorageReservation
    let control: PhysicalLogicWholeCandidateControl
    func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
        maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
        try control.check()
        if binding.key == root.binding.key {
            guard binding == root.binding else { throw PhysicalLogicWholeCandidateFlowFailure.source("Generated root binding differs") }
            try work.checkCancellation()
            return root
        }
        let value = try await parent.source(for: binding, work: work, maximumPageByteCount: maximumPageByteCount)
        try control.check()
        return value
    }
    static func replacingRoot(_ root: SPICECheckedSource, in input: SPICESimulationPreparationRequest,
        retaining constructionStorage: SPICESourceStorageReservation,
        control: PhysicalLogicWholeCandidateControl) throws -> SPICESimulationPreparationRequest {
        guard root.binding.key == input.root.binding.key else {
            throw PhysicalLogicWholeCandidateFlowFailure.source("Generated root must preserve include-route identity")
        }
        let slots = try PhysicalLogicWholeCandidateControl.product(UInt64(input.catalog.count), UInt64(MemoryLayout<SPICEExactSourceBinding>.stride))
        let bytes = try PhysicalLogicWholeCandidateControl.sum(UInt64(MemoryLayout<Self>.stride),
            PhysicalLogicWholeCandidateControl.sum(UInt64(MemoryLayout<[SPICEExactSourceBinding]>.stride), slots))
        let storage = try control.reserve(bytes, kind: .liveOwnedBytes)
        try control.check(UInt64(input.catalog.count))
        var catalog = [SPICEExactSourceBinding](repeating: root.binding, count: input.catalog.count)
        for index in input.catalog.indices {
            try control.check()
            let binding = input.catalog[index]
            if binding.key == root.binding.key {
                guard binding == input.root.binding else { throw PhysicalLogicWholeCandidateFlowFailure.source("Ambiguous original root catalog entry") }
                catalog[index] = root.binding
            } else { catalog[index] = binding }
        }
        let provider = Self(baseRoot: input.root, root: root, parent: input.provider, catalogStorage: storage, constructionStorage: constructionStorage, control: control)
        return SPICESimulationPreparationRequest(root: root, environment: input.environment,
            catalog: catalog, routes: input.routes, provider: provider, configuration: input.configuration,
            analysisIndex: input.analysisIndex, supplyBindings: input.supplyBindings, operatingPolicy: input.operatingPolicy,
            limits: input.limits, profile: input.profile, seed: input.seed, resolutionLimits: input.resolutionLimits,
            temperaturePolicy: input.temperaturePolicy, diodeProfile: input.diodeProfile, osdiInstances: input.osdiInstances,
            parameterOverrides: input.parameterOverrides, sourceOverrides: input.sourceOverrides,
            temperatureSelection: input.temperatureSelection, monteCarloSeedOverride: input.monteCarloSeedOverride,
            captureSourceScalars: input.captureSourceScalars, networkSelection: input.networkSelection,
            externalMOSPreparers: input.externalMOSPreparers)
    }
}
