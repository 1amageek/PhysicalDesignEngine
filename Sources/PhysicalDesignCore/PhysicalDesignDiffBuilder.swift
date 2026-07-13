import Foundation
import CircuiteFoundation

public struct PhysicalDesignDiffBuilder: Sendable {
    private let codec: PhysicalDesignJSONCodec

    public init(codec: PhysicalDesignJSONCodec = PhysicalDesignJSONCodec()) {
        self.codec = codec
    }

    public func build(
        runID: String,
        stage: PhysicalDesignStage,
        actor: String,
        before: PhysicalDesignSnapshot?,
        after: PhysicalDesignSnapshot,
        baseSnapshot: ArtifactReference?,
        proposedSnapshot: ArtifactReference?
    ) throws -> PhysicalDesignDesignDiff {
        let changes: [PhysicalDesignDesignDiffChange]
        if let before {
            changes = try fieldChanges(before: before, after: after, stage: stage)
        } else {
            changes = [
                PhysicalDesignDesignDiffChange(
                    changeID: "change-001",
                    domain: .layout,
                    operation: .add,
                    path: "/snapshot",
                    before: nil,
                    after: try codec.jsonValue(after),
                    summary: "Created the initial physical design snapshot."
                )
            ]
        }
        return PhysicalDesignDesignDiff(
            runID: runID,
            title: "Physical design \(stage.rawValue) revision",
            actor: actor,
            baseSnapshot: baseSnapshot,
            proposedSnapshot: proposedSnapshot,
            changes: changes,
            createdAt: Date()
        )
    }

    private func fieldChanges(
        before: PhysicalDesignSnapshot,
        after: PhysicalDesignSnapshot,
        stage: PhysicalDesignStage
    ) throws -> [PhysicalDesignDesignDiffChange] {
        var changes: [PhysicalDesignDesignDiffChange] = []
        var nextID = 1
        func appendChange<T: Encodable & Equatable>(
            _ path: String,
            _ beforeValue: T,
            _ afterValue: T,
            _ summary: String
        ) throws {
            guard beforeValue != afterValue else { return }
            changes.append(
                PhysicalDesignDesignDiffChange(
                    changeID: String(format: "change-%03d", nextID),
                    domain: .layout,
                    operation: .replace,
                    path: path,
                    before: try codec.jsonValue(beforeValue),
                    after: try codec.jsonValue(afterValue),
                    summary: summary
                )
            )
            nextID += 1
        }

        try appendChange("/die", before.die, after.die, "Updated die geometry.")
        try appendChange("/core", before.core, after.core, "Updated core geometry.")
        try appendChange("/rows", before.rows, after.rows, "Updated placement rows.")
        try appendChange("/cells", before.cells, after.cells, "Updated cell placement or cell masters.")
        try appendChange("/nets", before.nets, after.nets, "Updated net connectivity or antenna metadata.")
        try appendChange("/powerStructures", before.powerStructures, after.powerStructures, "Updated power structures.")
        try appendChange("/clockTrees", before.clockTrees, after.clockTrees, "Updated clock-tree topology.")
        try appendChange("/routes", before.routes, after.routes, "Updated routed geometry.")
        try appendChange("/vias", before.vias, after.vias, "Updated via topology.")
        try appendChange("/fills", before.fills, after.fills, "Updated fill geometry.")
        try appendChange("/hotspots", before.hotspots, after.hotspots, "Updated physical hotspot repair state.")
        try appendChange("/antennaRepairs", before.antennaRepairs, after.antennaRepairs, "Updated antenna repair records.")
        try appendChange("/implementationState", before.implementationState, after.implementationState, "Updated physical implementation constraints or proof evidence.")
        if changes.isEmpty {
            changes.append(
                PhysicalDesignDesignDiffChange(
                    changeID: "change-001",
                    domain: .layout,
                    operation: .metadata,
                    path: "/stage",
                    before: .string("unmodified"),
                    after: .string(stage.rawValue),
                    summary: "Stage completed without changing the canonical snapshot."
                )
            )
        }
        return changes
    }
}
