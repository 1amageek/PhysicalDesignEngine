import Foundation

public struct LocalPhysicalDesignClockTimingModelLoader: PhysicalDesignClockTimingModelLoading {
    private let codec: PhysicalDesignJSONCodec

    public init(codec: PhysicalDesignJSONCodec = PhysicalDesignJSONCodec()) {
        self.codec = codec
    }

    public func load(
        _ reference: PhysicalDesignClockTimingModelReference,
        from artifactStore: any PhysicalDesignArtifactStore
    ) async throws -> PhysicalDesignClockTimingModel {
        let references = [reference.modelArtifact] + reference.sourceArtifacts
        guard references.allSatisfy({ $0.locator.role == .input }) else {
            throw PhysicalDesignClockTimingModelError.invalidModel("all timing model artifacts must have the input role")
        }
        guard Set(references.map(\.id)).count == references.count else {
            throw PhysicalDesignClockTimingModelError.invalidModel("timing model artifact identities must be distinct")
        }
        guard reference.modelArtifact.locator.format == .json else {
            throw PhysicalDesignClockTimingModelError.invalidModel("timing characterization must be JSON")
        }
        let modelData = try await artifactStore.read(reference.modelArtifact)
        for source in reference.sourceArtifacts {
            _ = try await artifactStore.read(source)
        }
        let model = try codec.decode(PhysicalDesignClockTimingModel.self, from: modelData)
        try model.validate(against: reference)
        return model
    }
}
