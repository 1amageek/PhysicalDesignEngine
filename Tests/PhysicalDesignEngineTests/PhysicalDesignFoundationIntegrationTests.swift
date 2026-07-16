import Foundation
import Testing
import CircuiteFoundation
@testable import PhysicalDesignCore
@testable import PhysicalDesignEngine

@Suite("PhysicalDesignEngine CircuiteFoundation boundary")
struct PhysicalDesignFoundationIntegrationTests {
    @Test("native execution conforms directly to the Foundation engine boundary")
    func foundationExecutionBoundary() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let engine = PhysicalDesignEngine(artifactStore: store)
        let request = PhysicalDesignFixtureFactory.request(
            stage: .floorplan,
            snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
        )

        let result = try await engine.execute(request)

        #expect(result.status == .completed)
        #expect(result.runID == request.runID)
        #expect(result.artifacts.count == 4)
        #expect(result.evidence.artifacts == result.artifacts)
        #expect(result.evidence.provenance.inputs.isEmpty)
        #expect(result.diagnostics.allSatisfy { $0.code.rawValue.hasPrefix("physical-design.") })

    }

    @Test("physical requests expose a stable top-cell identity")
    func designObjectIdentity() throws {
        let request = PhysicalDesignFixtureFactory.request(
            stage: .floorplan,
            snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
        )

        #expect(request.design.topDesignName == "fixture_top")
        #expect(request.initialSnapshot?.topCell == "fixture_top")
    }

    @Test("artifact stores refuse to overwrite an immutable path")
    func artifactStoreIsImmutable() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        _ = try await store.write(
            Data("first".utf8),
            relativePath: "runs/immutable/revision.json",
            kind: .layout,
            format: .json,
            runID: "immutable"
        )

        do {
            _ = try await store.write(
                Data("second".utf8),
                relativePath: "runs/immutable/revision.json",
                kind: .layout,
                format: .json,
                runID: "immutable"
            )
            Issue.record("An immutable artifact path was overwritten")
        } catch let error as PhysicalDesignStoreError {
            #expect(error == .pathAlreadyExists("runs/immutable/revision.json"))
        }
    }

    @Test("filesystem artifact store refuses a path replacement")
    func filesystemArtifactStoreIsImmutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("physical-design-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Temporary artifact-store cleanup failed: \(error.localizedDescription)")
            }
        }

        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        _ = try await store.write(
            Data("first".utf8),
            relativePath: "runs/immutable/revision.json",
            kind: .layout,
            format: .json,
            runID: "immutable"
        )

        do {
            _ = try await store.write(
                Data("second".utf8),
                relativePath: "runs/immutable/revision.json",
                kind: .layout,
                format: .json,
                runID: "immutable"
            )
            Issue.record("A filesystem artifact path was overwritten")
        } catch let error as PhysicalDesignStoreError {
            #expect(error == .pathAlreadyExists("runs/immutable/revision.json"))
        }
    }

    @Test("filesystem artifact store rejects a symlink escape")
    func filesystemArtifactStoreRejectsSymlinkEscape() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("physical-design-root-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("physical-design-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
                try FileManager.default.removeItem(at: outside)
            } catch {
                Issue.record("Temporary symlink fixture cleanup failed: \(error.localizedDescription)")
            }
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)

        do {
            _ = try await store.write(
                Data("escaped".utf8),
                relativePath: "escape/revision.json",
                kind: .layout,
                format: .json,
                runID: "symlink-escape"
            )
            Issue.record("A symlink escaped the project root")
        } catch let error as PhysicalDesignStoreError {
            guard case .invalidPath = error else {
                Issue.record("Unexpected symlink error: \(error)")
                return
            }
        }
    }
}
