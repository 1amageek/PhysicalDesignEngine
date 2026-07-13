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
        let legacyEngine = PhysicalDesignEngine(artifactStore: store)
        let request = PhysicalDesignFixtureFactory.request(
            stage: .floorplan,
            snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
        )

        let result = try await legacyEngine.execute(request)

        #expect(result.status == .completed)
        #expect(result.runID == request.runID)
        #expect(result.artifacts.count == 4)
        #expect(result.evidence.artifacts == result.artifacts)
        #expect(result.evidence.provenance.inputs.isEmpty)
        #expect(result.diagnostics.allSatisfy { $0.code.rawValue.hasPrefix("physical-design.") })

        let evidence = PhysicalDesignFoundationEvidence(result: result)
        #expect(evidence.artifacts == result.artifacts)
        #expect(evidence.diagnostics == result.diagnostics)
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

    @Test("artifact conversion preserves the canonical Foundation reference")
    func artifactConversionPreservesCanonicalIdentity() throws {
        let reference = PhysicalDesignFixtureFactory.artifact(
            path: "runs/run/revision.json",
            kind: .layout,
            format: .json,
            role: .output
        )

        let converted = try PhysicalDesignFoundationArtifactConversion.reference(from: reference)

        #expect(converted.id == reference.id)
        #expect(converted.locator.format == .json)
        #expect(converted.locator.role == .output)
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
}
