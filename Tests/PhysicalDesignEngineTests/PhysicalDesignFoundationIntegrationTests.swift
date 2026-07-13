import Foundation
import Testing
import CircuiteFoundation
import XcircuitePackage
@testable import PhysicalDesignCore
@testable import PhysicalDesignEngine

@Suite("PhysicalDesignEngine CircuiteFoundation boundary")
struct PhysicalDesignFoundationIntegrationTests {
    @Test("native execution is exposed through the Foundation engine boundary")
    func foundationExecutionBoundary() async throws {
        let store = InMemoryPhysicalDesignArtifactStore()
        let legacyEngine = PhysicalDesignEngine(artifactStore: store)
        let request = PhysicalDesignFixtureFactory.request(
            stage: .floorplan,
            snapshot: PhysicalDesignFixtureFactory.snapshot(includeFloorplan: false)
        )

        let result = try await PhysicalDesignFoundationEngine(legacyEngine: legacyEngine).execute(request)

        #expect(result.status == .completed)
        #expect(result.runID == request.runID)
        #expect(result.stage == request.stage)
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

        let reference = try request.designObjectReference()

        #expect(reference.kind == .cell)
        #expect(reference.identifier == "fixture_top")
        #expect(reference.hierarchy == .root)
    }

    @Test("legacy artifact references convert only with verified integrity metadata")
    func artifactConversionRequiresIntegrity() throws {
        let reference = XcircuiteFileReference(
            artifactID: "legacy-artifact",
            path: "runs/run/revision.json",
            kind: .layout,
            format: .json
        )

        do {
            _ = try PhysicalDesignFoundationArtifactConversion.reference(from: reference)
            Issue.record("An artifact without digest and byte count unexpectedly crossed the Foundation boundary")
        } catch let error as PhysicalDesignFoundationBoundaryError {
            #expect(error == .missingDigest("runs/run/revision.json"))
        }
    }

    @Test("artifact conversion preserves opaque legacy identity")
    func artifactConversionPreservesOpaqueIdentity() throws {
        let reference = XcircuiteFileReference(
            artifactID: "layout-revision",
            path: "runs/run/revision.json",
            kind: .layout,
            format: .json,
            sha256: String(repeating: "a", count: 64),
            byteCount: 1
        )

        let converted = try PhysicalDesignFoundationArtifactConversion.reference(
            from: reference
        )

        #expect(converted.id.rawValue == "layout-revision")
        #expect(converted.locator.format == .json)
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
