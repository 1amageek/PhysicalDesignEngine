import Foundation
import Testing
import PhysicalDesignEngine
@testable import PhysicalDesignCore

@Suite("Source-bound standard layout export")
struct StandardLayoutExportTests {
    let limits = PhysicalDesignStandardLayoutExportLimits(maximumInputByteCount: 1_000_000, maximumGeometryRecordCount: 100_000, maximumOutputByteCount: 1_000_000)

    @Test("public export pairs the actual native producer bytes", .timeLimit(.minutes(1)))
    func nativeProducerPairing() async throws {
        let (request, snapshot, store, producer) = try await fixture()
        let before = try PhysicalDesignJSONCodec().encode(snapshot)
        let exporter: any PhysicalDesignStandardLayoutExporting = NativePhysicalDesignStandardLayoutExporter()
        let actual = try await exporter.exportDEF(snapshot: snapshot, request: request, artifactStore: store, limits: limits)
        #expect(try PhysicalDesignJSONCodec().encode(snapshot) == before)
        #expect(actual == producer)
        let exact = PhysicalDesignStandardLayoutExportLimits(maximumInputByteCount: limits.maximumInputByteCount, maximumGeometryRecordCount: limits.maximumGeometryRecordCount, maximumOutputByteCount: UInt64(producer.count))
        #expect(try await exporter.exportDEF(snapshot: snapshot, request: request, artifactStore: store, limits: exact) == producer)
        #expect(String(decoding: actual, as: UTF8.self).contains("- N ( U1 Y ) + ROUTED metH ( 1000 1000 ) hv ;\n"))
    }

    @Test("source substitutions fail before any reads or writes", .timeLimit(.minutes(1)))
    func sourcePairingIsExact() async throws {
        let (request, snapshot, store, _) = try await fixture()
        let observed = ExportReadProbe(store: store)
        var changed = snapshot
        changed.processAssets.removeValue(forKey: "tech")
        do {
            _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: changed, request: request, artifactStore: observed, limits: limits)
            Issue.record("Substituted sources were admitted.")
        } catch PhysicalDesignStandardLayoutExportError.sourceIdentityMismatch { }
        #expect(await observed.reads == 0)
        #expect(await observed.writes == 0)
    }

    @Test("untrusted store bytes must match actual size and digest", .timeLimit(.minutes(1)))
    func actualSourceBytesAreVerified() async throws {
        let (request, snapshot, store, _) = try await fixture()
        for mode in [ExportReadProbe.Mode.wrongSize, .wrongDigest] {
            let observed = ExportReadProbe(store: store, mode: mode)
            do {
                _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: observed, limits: limits)
                Issue.record("Forged bytes were admitted.")
            } catch PhysicalDesignStandardLayoutExportError.sourceIdentityMismatch { }
            #expect(await observed.reads == 1)
            #expect(await observed.writes == 0)
        }
    }

    @Test("all three caller budgets reject atomically", .timeLimit(.minutes(1)))
    func budgetsArePrecharged() async throws {
        let (request, snapshot, store, producer) = try await fixture()
        let cases: [(PhysicalDesignStandardLayoutExportLimits, PhysicalDesignStandardLayoutExportError.Resource)] = [
            (.init(maximumInputByteCount: 0, maximumGeometryRecordCount: 100_000, maximumOutputByteCount: 1_000_000), .inputBytes),
            (.init(maximumInputByteCount: 1_000_000, maximumGeometryRecordCount: 0, maximumOutputByteCount: 1_000_000), .geometryRecords),
            (.init(maximumInputByteCount: 1_000_000, maximumGeometryRecordCount: 100_000, maximumOutputByteCount: UInt64(producer.count - 1)), .outputBytes)
        ]
        for (budget, expected) in cases {
            let observed = ExportReadProbe(store: store)
            do {
                _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: observed, limits: budget)
                Issue.record("Exceeded budget was admitted.")
            } catch PhysicalDesignStandardLayoutExportError.limitExceeded(let actual) { #expect(actual == expected) }
            if expected == .inputBytes { #expect(await observed.reads == 0) }
            #expect(await observed.writes == 0)
        }
    }

    @Test("source vertices are charged for each instance before projection", .timeLimit(.minutes(1)))
    func projectedMultiplicityIsBounded() async throws {
        let (request, snapshot, store, _) = try await fixture()
        let bounded = PhysicalDesignStandardLayoutExportLimits(maximumInputByteCount: 1_000_000, maximumGeometryRecordCount: 500, maximumOutputByteCount: 1_000_000)
        _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: store, limits: bounded)
        var repeated = snapshot
        for index in 1...20 {
            var cell = snapshot.cells[0]
            cell.id = "repeated-\(index)"
            repeated.cells.append(cell)
        }
        do {
            _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: repeated, request: request, artifactStore: store, limits: bounded)
            Issue.record("Repeated source projections bypassed the geometry ceiling.")
        } catch PhysicalDesignStandardLayoutExportError.limitExceeded(.geometryRecords) { }
    }

    @Test("read failure and cancellation remain typed", .timeLimit(.minutes(1)))
    func failureAndCancellation() async throws {
        let (request, snapshot, store, _) = try await fixture()
        let failed = ExportReadProbe(store: store, mode: .failed)
        do {
            _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: failed, limits: limits)
            Issue.record("Read failure succeeded.")
        } catch PhysicalDesignStandardLayoutExportError.artifactReadFailed { }
        let cancelled = ExportReadProbe(store: store, mode: .cancelled)
        do {
            _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: cancelled, limits: limits)
            Issue.record("Cancellation succeeded.")
        } catch PhysicalDesignStandardLayoutExportError.cancelled { }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: failed, limits: limits)
        }
        do { _ = try await task.value; Issue.record("Pre-cancelled export succeeded.") }
        catch PhysicalDesignStandardLayoutExportError.cancelled { }
        #expect(await failed.reads == 1)
        #expect(await failed.writes == 0)
    }

    @Test("source geometry and unsupported interchange fail without changing proof state", .timeLimit(.minutes(1)))
    func snapshotAdmissionAndProofOwnership() async throws {
        let (request, original, store, producer) = try await fixture()
        var snapshot = original
        snapshot.implementationState?.placementProof = .init(cellCount: 1, legalCellCount: 0, overlapCount: 0, outsideCoreCount: 0, blockageConflictCount: 0, blockedCellCount: 1, utilization: 0, wirelengthObjectiveDBU: 0, congestionObjective: 0)
        snapshot.implementationState?.routingEvidence = .init(mode: "retained-unverified", routedNetCount: 0)
        snapshot.implementationState?.repairProofs = [.init(stage: "retained", strategy: "unverified", targetIDs: ["U1"], violationsBefore: 1, violationsAfter: 1, verified: false)]
        let before = try PhysicalDesignJSONCodec().encode(snapshot)
        #expect(try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: store, limits: limits) == producer)
        #expect(try PhysicalDesignJSONCodec().encode(snapshot) == before)
        snapshot.cells[0].width += 1
        do {
            _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: store, limits: limits)
            Issue.record("Contradictory source SIZE succeeded.")
        } catch PhysicalDesignStandardLayoutExportError.invalidSnapshot { }
        snapshot = original
        snapshot.powerStructures = [.init(id: "power", netID: "N", kind: "power", layer: 2, geometry: .init(x: 0, y: 0, width: 100, height: 100))]
        do {
            _ = try await NativePhysicalDesignStandardLayoutExporter().exportDEF(snapshot: snapshot, request: request, artifactStore: store, limits: limits)
            Issue.record("Unsupported source-bound special-net export succeeded.")
        } catch PhysicalDesignStandardLayoutExportError.encodingFailed { }
    }

    private func fixture() async throws -> (PhysicalDesignRequest, PhysicalDesignSnapshot, InMemoryPhysicalDesignArtifactStore, Data) {
        let (_, base, store) = try await ProcessGeometryTests().fixture()
        var request = ProcessGeometryTests().nativeRequest(base)
        request.runID = "standard-export-pairing"
        request.initialSnapshot?.nets = [.init(id: "N", pinIDs: ["U1/Y"])]
        request.initialSnapshot?.pins[0].netID = "N"
        request.initialSnapshot?.vias = [.init(id: "V", netID: "N", x: 1000, y: 1000, lowerLayer: 2, upperLayer: 3, master: "hv")]
        let result = try await PhysicalDesignEngine(artifactStore: store).execute(request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let layout = try #require(result.payload.physicalDesign?.layoutArtifact)
        let snapshot = try PhysicalDesignJSONCodec().decode(PhysicalDesignSnapshot.self, from: await store.read(layout))
        let def = try #require(result.artifactBindings.first { $0.descriptor.format == .def })
        return (request, snapshot, store, try await store.read(def))
    }
}

private actor ExportReadProbe: PhysicalDesignArtifactStore {
    enum Mode { case unchanged, wrongSize, wrongDigest, failed, cancelled }
    let store: InMemoryPhysicalDesignArtifactStore
    let mode: Mode
    private(set) var reads = 0
    private(set) var writes = 0

    init(store: InMemoryPhysicalDesignArtifactStore, mode: Mode = .unchanged) { self.store = store; self.mode = mode }

    func read(_ binding: PhysicalDesignArtifactBinding) async throws -> Data {
        reads += 1
        if mode == .cancelled { throw CancellationError() }
        if mode == .failed { throw PhysicalDesignStoreError.readFailed("Fixture read failure") }
        var bytes = try await store.read(binding)
        if mode == .wrongSize { bytes.append(0) }
        if mode == .wrongDigest { bytes[bytes.startIndex] ^= 1 }
        return bytes
    }

    func write(_ artifacts: [PhysicalDesignArtifactWrite]) async throws -> [PhysicalDesignArtifactBinding] {
        writes += 1
        throw PhysicalDesignStoreError.writeFailed("Export must not write")
    }
}
