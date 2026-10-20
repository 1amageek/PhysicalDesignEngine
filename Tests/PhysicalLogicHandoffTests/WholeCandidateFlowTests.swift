import Foundation
import Synchronization
import CircuiteFoundation
import CoreSpice
import CoreSpiceIO
import LogicEngineRuntime
import PhysicalDesignCore
import PhysicalDesignLogicHandoff
import STAEngine
import TimingCore
import Testing

@Suite("Actual assessed-candidate conditional electrical flow", .serialized, .timeLimit(.minutes(2)))
struct WholeCandidateFlowTests {
    private func fixture(_ body: (WholeCandidateFlowFixture, WholeCandidateFlowSDKFixture) async throws -> Void) async throws {
        let root = try PhysicalLogicHandoffTests().temporary()
        do {
            let physical = try await WholeCandidateFlowFixture.make(root: root)
            let sdk = try WholeCandidateFlowSDKFixture.make(root: root)
            do { try await body(physical, sdk) }
            catch {
                let primary = error
                do { try await sdk.capability.close().wait() }
                catch { throw WholeCandidateFlowFixture.Failure.cleanup(primary: primary, secondary: error) }
                throw primary
            }
            try await sdk.capability.close().wait()
            let survivors = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sdk").path)
            #expect(Set(survivors) == ["linear.osdi", "worker"])
            try FileManager.default.removeItem(at: root)
        } catch {
            let primary = error
            do { try FileManager.default.removeItem(at: root) }
            catch { throw WholeCandidateFlowFixture.Failure.cleanup(primary: primary, secondary: error) }
            throw primary
        }
    }
    private func invoke(_ f: WholeCandidateFlowFixture, _ request: PhysicalLogicWholeCandidateFlowRequest,
        resources: WholeCandidateFlowResources, assessment: PhysicalLogicECOAssessment? = nil,
        limits: PhysicalLogicWholeCandidateFlowLimits? = nil, cancellation: CancellationToken = .init())
        async throws -> PhysicalLogicWholeCandidateFlow {
        var context = try WholeCandidateFlowFixture.context()
        return try await (assessment ?? f.assessment).certifyWholeCandidateFlow(preparedSTA: f.prepared,
            request: request, limits: limits ?? WholeCandidateFlowFixture.limits(),
            context: &context, resources: resources, cancellation: cancellation)
    }
    private enum Phase { case candidate, source, parasitics, rail, time, family, internalOutput, resource, cancelled }
    private func refuses(_ phase: Phase, _ operation: () async throws -> PhysicalLogicWholeCandidateFlow,
        sourceLocation: Testing.SourceLocation = #_sourceLocation) async throws {
        do {
            _ = try await operation()
            Issue.record("An invalid whole-candidate request published a seal", sourceLocation: sourceLocation)
        } catch let failure as PhysicalLogicWholeCandidateFlowFailure {
            switch (phase, failure) {
            case (.candidate, .candidate), (.source, .source), (.parasitics, .parasitics),
                 (.rail, .rail), (.time, .time), (.family, .family),
                 (.internalOutput, .internalOutput), (.resource, .resource), (.cancelled, .cancelled): break
            default: throw failure
            }
        }
    }

    private func refusesCompleteFamily(at expectedIndex: Int,
        _ operation: () async throws -> PhysicalLogicWholeCandidateFlow) async throws {
        do {
            _ = try await operation()
            Issue.record("An incomplete initial/window/rate family published a seal")
        } catch PhysicalLogicWholeCandidateFlowFailure.family(let index, let reason) {
            #expect(index == expectedIndex)
            #expect(reason == "Complete initial/window/SI-rate family is not covered")
        }
    }
    private func refusesForgedPreparedContext(
        _ operation: () async throws -> PhysicalLogicWholeCandidateFlow) async throws {
        do {
            _ = try await operation()
            Issue.record("A forged decoded context replaced the actual Prepared STA authority")
        } catch PhysicalLogicWholeCandidateFlowFailure.lower(phase: .family, cause: let cause) {
            guard case STAExecutionError.underlying(let underlying) = cause,
                  case TimingError.invalidInput(let message) = underlying else { throw cause }
            #expect(message == "Initial source jet: prepared context mismatch")
        }
    }

    @Test func actualSDKFlowSurvivesCandidateColdReloadAndFinalCopiedOwner() async throws {
        try await fixture { f, sdk in
            let resources = try WholeCandidateFlowResources()
            var retainedSlices: SPICEAccountedCollection<STAConservativeSourceJointSlice>?
            do {
                // Persist and reload the ACTUAL functional proof and candidate. A decoded snapshot is not authority.
                let store = FileSystemPhysicalDesignArtifactStore(projectRoot: f.root)
                let persistence = NativePhysicalLogicCheckedCandidatePersistence()
                var write = try WholeCandidateFlowFixture.context()
                let savedLayout = try await store.write(PhysicalDesignJSONCodec().encode(f.assessment.candidate),
                    logicalID: "whole-candidate", relativePath: "candidate.json", kind: .layout, format: .json, runID: "whole-flow")
                let artifacts = try await persistence.persist(f.assessment,
                    candidateReference: .init(layoutArtifact: savedLayout, topCell: "top",
                        layoutDigest: savedLayout.reference.digest.hexadecimalValue), store: store,
                    runID: "whole-flow", relativeDirectory: "saved-candidate",
                    limits: WholeCandidateFlowFixture.handoffLimits(), maximumArtifactBytes: 8_388_608, context: &write)
                // Read the actual bytes again through a fresh store and decode the public artifact record.
                let record = try JSONDecoder().decode(PhysicalLogicCheckedCandidateArtifacts.self,
                    from: JSONEncoder().encode(artifacts))
                var read = try WholeCandidateFlowFixture.context()
                let reloaded = try await persistence.reload(record, baseline: f.baseline,
                    store: FileSystemPhysicalDesignArtifactStore(projectRoot: f.root),
                    limits: WholeCandidateFlowFixture.handoffLimits(), maximumArtifactBytes: 8_388_608, context: &read)
                try reloaded.requireBinding(to: f.assessment.candidate)
                let request = try await f.request(sdk: sdk, resources: resources)
                var original: PhysicalLogicWholeCandidateFlow? = try await invoke(f, request, resources: resources, assessment: reloaded)
                #expect(resources.counts.live > 0)
                var copy = original; original = nil
                do {
                    let result = try #require(copy)
                    #expect(result.preparedSTA.executionInputIdentity == f.prepared.executionInputIdentity
                        && result.preparedSTA.configurationDigest == f.prepared.configurationDigest)
                    #expect(result.timingContext.record == f.family.record)
                    #expect(result.jointSlices.count == f.family.record.sources.count)
                    retainedSlices = result.jointSlices
                    #expect(result.observations.count == result.jointSlices.count)
                    let port = try #require(f.family.record.sources.firstIndex { $0.origin == .primaryPort })
                    let output = try #require(f.family.record.sources.firstIndex { $0.origin == .prescribedCellOutput })
                    let primary = try result.observations.observation(at: port)
                    let internalOutput = try result.observations.observation(at: output)
                    #expect(result.jointSlices[port].windowValue == 0...1)
                    #expect(result.jointSlices[port].almostEverywhereSlope.contains(0))
                    WholeCandidateFlowFixture.contains(primary.windowVoltage, 0)
                    WholeCandidateFlowFixture.contains(primary.windowVoltage, 1)
                    WholeCandidateFlowFixture.contains(primary.almostEverywhereRate, 0)
                    // Rtotal=1+2=3 and Ctotal=2+1=3. The constant U=.5 member has Y=.5.
                    WholeCandidateFlowFixture.contains(internalOutput.initialVoltage, 0.5)
                    WholeCandidateFlowFixture.contains(internalOutput.windowVoltage, 0.5)
                    WholeCandidateFlowFixture.contains(internalOutput.almostEverywhereRate, 0)
                    // Constant U=0 and U=1 are also members: Y'=(U-Y)/9 at Y=.5.
                    WholeCandidateFlowFixture.contains(internalOutput.almostEverywhereRate, -1.0 / 18)
                    WholeCandidateFlowFixture.contains(internalOutput.almostEverywhereRate, 1.0 / 18)
                    let h = request.native.flow.duration.high
                    WholeCandidateFlowFixture.contains(try result.observations.flow.endpointCharge(at: 0), 1.5 * exp(-h / 9))
                    WholeCandidateFlowFixture.contains(try result.observations.flow.endpointCharge(at: 0), 3 - 1.5 * exp(-h / 9))
                    #expect(internalOutput.almostEverywhereRate.absoluteUpperBound < 1)
                    #expect(result.observations.flow.contractionUpperBound >= 0
                        && result.observations.flow.contractionUpperBound < 1)
                    try result.observations.flow.withScope { scope in
                        let countsMatch = scope.sources.count == 1 && scope.models.count == 1
                        let programMatches = scope.models[0].windowBinding.source.programDigest.hexadecimalValue
                            == "2dd3c8f0a814583b8c6118825393a350f4e2f64d112a6a53060aeba20bf4b203"
                        let hasGround = scope.models[0].preparation.rawNodeGlobalRows.contains(nil)
                        let timeMatches = scope.startTime == request.native.flow.startTime && scope.duration == request.native.flow.duration
                        #expect(countsMatch)
                        #expect(programMatches)
                        #expect(hasGround)
                        #expect(timeMatches)
                    }
                    let before = resources.counts
                    for _ in 0..<16 {
                        result.observations.withObservations { rows in
                            let count = rows.count
                            #expect(count == result.jointSlices.count)
                        }
                    }
                    #expect(resources.counts.work == before.work && resources.counts.acquisitions == before.acquisitions)
                    #expect(result.sourcePreparation.sources.count > 0)
                    #expect(result.sourcePreparation.circuit.instances.filter { $0.typeName == "resistor" }.count == 3)
                    #expect(result.sourcePreparation.circuit.instances.filter { $0.typeName == "capacitor" }.count == 1)
                }
                copy = nil
            }
            do {
                let slices = try #require(retainedSlices)
                #expect(slices.count == f.family.record.sources.count && resources.counts.live > 0)
                #expect(slices[0].contextRecord == f.family.record)
            }
            retainedSlices = nil
            resources.expectRefund()
        }
    }

    @Test func completeUnrestrictedFamilyRejectsPointValueAndNonzeroOnlyRate() async throws {
        try await fixture { f, sdk in
            let resources = try WholeCandidateFlowResources()
            do {
                let index = try #require(f.family.record.sources.firstIndex { $0.origin == .primaryPort })
                let slice = try f.family.jointSlice(sourceAt: index, initialTime: 0.25...Double(0.25).nextUp,
                    over: 0.25...(0.25 + 1e-12).nextUp)
                // The actual unrestricted family includes the constant member U=.5, U'=0.
                #expect(slice.initialValue.contains(0.5) && slice.windowValue.contains(0.5)
                    && slice.almostEverywhereSlope.contains(0))
                let point = try await f.flow(sdk: sdk, initial: 0.5...0.5, values: 0.5...0.5, derivative: 1...1)
                let request = try await f.request(sdk: sdk, resources: resources, flow: point)
                try await refusesCompleteFamily(at: index) { try await invoke(f, request, resources: resources) }
                // Full values alone cannot repair the omitted zero-slope histories.
                let rateOnly = try await f.flow(sdk: sdk, derivative: 1...1)
                let second = try await f.request(sdk: sdk, resources: resources, flow: rateOnly)
                try await refusesCompleteFamily(at: index) { try await invoke(f, second, resources: resources) }
            }
            resources.expectRefund()
        }
    }

    @Test func originalSourcePinInventoryParasiticCornerRailAndTimeRefuseTheirOwnStage() async throws {
        try await fixture { f, sdk in
            let resources = try WholeCandidateFlowResources()
            do {
                let proposal = try await f.flow(sdk: sdk)
                let missing = try await f.request(sdk: sdk, resources: resources, flow: proposal, pinNodes: ["port-a": "a"])
                try await refuses(.candidate) { try await invoke(f, missing, resources: resources) }
                let shorted = try await f.request(sdk: sdk, resources: resources, flow: proposal,
                    pinNodes: ["port-a": "a", "new-buffer/A": "a", "new-buffer/Y": "new-buffer:Y", "port-y": "y"])
                try await refuses(.source) { try await invoke(f, shorted, resources: resources) }
                let changedMaster = try await f.request(sdk: sdk, resources: resources,
                    text: WholeCandidateFlowFixture.source.replacingOccurrences(of: " 0 BUF", with: " 0 OTHER"), flow: proposal)
                do {
                    _ = try await invoke(f, changedMaster, resources: resources)
                    Issue.record("Undefined original cell master was accepted")
                } catch PhysicalLogicWholeCandidateFlowFailure.lower(phase: .source, cause: let cause) {
                    guard case SPICESimulationPreparationError.resource(let underlying) = cause,
                          case LoweringError.undefinedSubcircuit(let name, _) = underlying else { throw cause }
                    #expect(name.lowercased() == "other")
                }
                // This checks the explicit execution-label association, not SPEF/foundry PVT provenance.
                let wrongCorner = try await f.request(sdk: sdk, resources: resources, flow: proposal, corner: .init("slow"))
                try await refuses(.parasitics) { try await invoke(f, wrongCorner, resources: resources) }
                var bytes = f.spef; bytes.append(0x20)
                let staleBytes = try await f.request(sdk: sdk, resources: resources, flow: proposal, spefBytes: bytes)
                try await refuses(.parasitics) { try await invoke(f, staleBytes, resources: resources) }
                let changedRail = try await f.request(sdk: sdk, resources: resources, flow: proposal,
                    rail: .init(sourceName: "VDD", zeroNode: "0", oneNode: "vdd", zeroVoltage: 0, oneVoltage: 2))
                try await refuses(.rail) { try await invoke(f, changedRail, resources: resources) }
                let body = try await f.request(sdk: sdk, resources: resources,
                    text: WholeCandidateFlowFixture.source.replacingOccurrences(of: "vdd 0 vdd 0 BUF", with: "vdd 0 0 0 BUF"), flow: proposal)
                try await refuses(.rail) { try await invoke(f, body, resources: resources) }
                // Omitting the represented low component loses the real initial-time point.
                let time = try await f.request(sdk: sdk, resources: resources, flow: proposal, initialTime: 0.25...0.25)
                try await refuses(.time) { try await invoke(f, time, resources: resources) }
            }
            resources.expectRefund()
        }
    }

    @Test func endogenousOutputsCannotBeIndependentSourcesAndAllAssociationsAreRequired() async throws {
        try await fixture { f, sdk in
            let resources = try WholeCandidateFlowResources()
            do {
                let proposal = try await f.flow(sdk: sdk)
                var bindings = try await f.request(sdk: sdk, resources: resources, flow: proposal).sourceBindings
                let output = try #require(bindings.firstIndex { $0.sourceDeviceName == nil })
                bindings[output] = .init(sourceIndex: bindings[output].sourceIndex,
                    physicalPinID: bindings[output].physicalPinID, sourceDeviceName: "VOUT")
                let forced = try await f.request(sdk: sdk, resources: resources,
                    text: WholeCandidateFlowFixture.source.replacingOccurrences(of: ".tran", with: "VOUT new-buffer:Y 0 .5\n.tran"),
                    flow: proposal, bindings: bindings)
                try await refuses(.internalOutput) { try await invoke(f, forced, resources: resources) }
                let missing = try await f.request(sdk: sdk, resources: resources, flow: proposal, bindings: [])
                try await refuses(.family) { try await invoke(f, missing, resources: resources) }
                let duplicate = try await f.request(sdk: sdk, resources: resources, flow: proposal, bindings: [bindings[0], bindings[0]])
                try await refuses(.family) { try await invoke(f, duplicate, resources: resources) }
            }
            resources.expectRefund()
        }
    }

    @Test func cancellationAndOwnedCapacityCannotPublishOrLeakAWholeSeal() async throws {
        try await fixture { f, sdk in
            let resources = try WholeCandidateFlowResources()
            do {
                let request = try await f.request(sdk: sdk, resources: resources)
                let baseline = resources.counts
                let cancelled = CancellationToken(); cancelled.cancel()
                try await refuses(.cancelled) { try await invoke(f, request, resources: resources, cancellation: cancelled) }
                #expect(resources.counts.live == baseline.live && resources.counts.temporary == baseline.temporary)
                resources.refuseNextCharge()
                do {
                    _ = try await invoke(f, request, resources: resources)
                    Issue.record("The same cumulative accountant refusal was ignored")
                } catch PhysicalLogicWholeCandidateFlowFailure.resource(let cause) {
                    guard case WholeCandidateFlowResources.Refusal.quota = cause else { throw cause }
                }
                resources.refuseNextReservation()
                do {
                    _ = try await invoke(f, request, resources: resources)
                    Issue.record("The same allocator admission refusal was ignored")
                } catch PhysicalLogicWholeCandidateFlowFailure.resource(let cause) {
                    guard case WholeCandidateFlowResources.Refusal.storage = cause else { throw cause }
                }
                let during = CancellationToken()
                resources.cancelAfterNextCharge(during)
                try await refuses(.cancelled) { try await invoke(f, request, resources: resources, cancellation: during) }
                #expect(during.isCancelled)
                #expect(resources.counts.live == baseline.live && resources.counts.temporary == baseline.temporary)
                // The finite exact source must be admitted before any owned composition can publish.
                do {
                    _ = try await invoke(f, request, resources: resources,
                        limits: WholeCandidateFlowFixture.limits(sourceBytes: 1))
                    Issue.record("Whole source byte capacity was bypassed")
                } catch PhysicalLogicWholeCandidateFlowFailure.invalidInput { }
                #expect(resources.counts.live == baseline.live && resources.counts.temporary == baseline.temporary)
            }
            resources.expectRefund()
        }
    }
}

extension WholeCandidateFlowTests {
    @Test func decodedInternalArcLoadAndThresholdClaimsCannotReplacePreparedAuthority() async throws {
        try await fixture { f, sdk in
            let resources = try WholeCandidateFlowResources()
            do {
                let proposal = try await f.flow(sdk: sdk)
                let internalIndex = try #require(f.family.record.sources.firstIndex { $0.origin == .prescribedCellOutput })
                let original = try JSONEncoder().encode(f.family.record)
                for mutation in 0..<3 {
                    var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
                    if mutation == 2 {
                        var thresholds = try #require(object["thresholds"] as? [Double])
                        thresholds[0] += 1
                        object["thresholds"] = thresholds
                    } else {
                        var sources = try #require(object["sources"] as? [[String: Any]])
                        var authority = try #require(sources[internalIndex]["authority"] as? [String: Any])
                        if mutation == 0 {
                            let load = try #require(authority["prescribedBoundaryLoad"] as? Double)
                            authority["prescribedBoundaryLoad"] = load + 0.25
                        } else {
                            let arcs = try #require(authority["sourceArcs"] as? [[String: Any]])
                            #expect(!arcs.isEmpty)
                            authority["sourceArcs"] = arcs + arcs
                        }
                        sources[internalIndex]["authority"] = authority; object["sources"] = sources
                    }
                    let forged = try JSONDecoder().decode(STAConservativeSourceContextRecord.self,
                        from: JSONSerialization.data(withJSONObject: object))
                    #expect(forged != f.family.record)
                    let request = try await f.request(sdk: sdk, resources: resources, flow: proposal, timingContext: forged)
                    try await refusesForgedPreparedContext { try await invoke(f, request, resources: resources) }
                }
            }
            resources.expectRefund()
        }
    }
}

extension WholeCandidateFlowTests {
    /// Observes only the new directory created by this serialized suite's actual producer.
    /// Filesystem operations and cancellation run outside every tracker/probe mutex.
    private final class StagingProbe: Sendable {
        enum Mode: Sendable { case cancel(CancellationToken), error, retreat(replace: Bool) }
        struct State: Sendable {
            var claimed = false
            var directory: URL?
            var retreat: URL?
            var fileBytes: UInt64 = 0
        }
        let baseline: Set<String>
        let root: URL
        let mode: Mode
        private let state = Mutex(State())
        init(root: URL, mode: Mode) throws {
            self.root = root; self.mode = mode
            baseline = try Self.directories()
        }
        var captured: State { state.withLock { $0 } }
        private static func directories() throws -> Set<String> {
            let base = FileManager.default.temporaryDirectory
            return Set(try FileManager.default.contentsOfDirectory(atPath: base.path)
                .filter { $0.hasPrefix("physical-whole-candidate-") })
        }
        func observe() throws {
            if state.withLock({ $0.claimed }) { return }
            let directory: URL
            if let cached = state.withLock({ $0.directory }) { directory = cached }
            else {
                let names = try Self.directories().subtracting(baseline)
                guard !names.isEmpty else { return }
                guard names.count == 1, let name = names.first else {
                    throw WholeCandidateFlowFixture.Failure.mismatch("Ambiguous concurrently created staging directories")
                }
                directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
                state.withLock { $0.directory = directory }
            }
            let fragment = directory.appendingPathComponent("fragment.cir")
            guard FileManager.default.fileExists(atPath: fragment.path) else { return }
            let size = try fragment.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size > 0 else { throw WholeCandidateFlowFixture.Failure.mismatch("Empty actual PEX fragment") }
            let claimed = state.withLock { state in
                if state.claimed { return false }
                state.claimed = true; state.directory = directory; state.fileBytes = UInt64(size)
                return true
            }
            guard claimed else { return }
            switch mode {
            case .cancel(let token): token.cancel()
            case .error: throw WholeCandidateFlowResources.Refusal.quota
            case .retreat(let replace):
                let saved = root.appendingPathComponent("retreated-producer-staging", isDirectory: true)
                try FileManager.default.moveItem(at: directory, to: saved)
                state.withLock { $0.retreat = saved }
                if replace {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    try Data("owned replacement sentinel".utf8).write(to: directory.appendingPathComponent("replacement.txt"), options: .withoutOverwriting)
                }
                throw WholeCandidateFlowResources.Refusal.quota
            }
        }
        func restore() throws {
            let captured = self.captured
            guard let original = captured.directory, let saved = captured.retreat else { return }
            guard FileManager.default.fileExists(atPath: saved.path) else { return }
            if FileManager.default.fileExists(atPath: original.path) {
                guard case .retreat(replace: true) = mode else {
                    throw WholeCandidateFlowFixture.Failure.mismatch("An unexpected path occupies the missing producer directory")
                }
                let marker = try Data(contentsOf: original.appendingPathComponent("replacement.txt"))
                guard marker == Data("owned replacement sentinel".utf8) else {
                    throw WholeCandidateFlowFixture.Failure.mismatch("Replacement changed before explicit test restoration")
                }
                // This is the replacement created above, never a general recursive cleanup target.
                try FileManager.default.removeItem(at: original)
            }
            try FileManager.default.moveItem(at: saved, to: original)
        }
    }

    @Test func stagingCancellationAndCallerErrorAwaitActualFileAndDirectoryRefund() async throws {
        try await fixture { f, sdk in
            for cancel in [false, true] {
                let token = CancellationToken()
                let probe = try StagingProbe(root: f.root, mode: cancel ? .cancel(token) : .error)
                let resources = try WholeCandidateFlowResources(onReservation: { kind, _ in
                    if kind == .liveOwnedBytes { try probe.observe() }
                })
                do {
                    let request = try await f.request(sdk: sdk, resources: resources)
                    let before = resources.counts
                    do {
                        _ = try await invoke(f, request, resources: resources, cancellation: token)
                        Issue.record("Producer published despite cancellation/error after the actual file write")
                    } catch PhysicalLogicWholeCandidateFlowFailure.cancelled where cancel {
                        #expect(token.isCancelled)
                    } catch PhysicalLogicWholeCandidateFlowFailure.resource(let cause) where !cancel {
                        guard case WholeCandidateFlowResources.Refusal.quota = cause else { throw cause }
                    }
                    let captured = probe.captured
                    let directory = try #require(captured.directory)
                    #expect(captured.fileBytes > 0 && !FileManager.default.fileExists(atPath: directory.path))
                    #expect(resources.counts.live == before.live && resources.counts.temporary == before.temporary)
                }
                resources.expectRefund()
            }
        }
    }

    @Test(arguments: [false, true])
    func missingOrReplacedOwnedDirectoryRetainsRetryCauseAndFinalCopiedFailure(_ replace: Bool) async throws {
        try await fixture { f, sdk in
            let probe = try StagingProbe(root: f.root, mode: .retreat(replace: replace))
            let resources = try WholeCandidateFlowResources(onReservation: { kind, _ in
                    if kind == .liveOwnedBytes { try probe.observe() }
                })
            let cancellation = CancellationToken()
            var original: PhysicalLogicWholeCandidateStagingCleanupFailure?
            var copy: PhysicalLogicWholeCandidateStagingCleanupFailure?
            do {
                do {
                    let request = try await f.request(sdk: sdk, resources: resources)
                    do {
                        _ = try await invoke(f, request, resources: resources, cancellation: cancellation)
                        Issue.record("Missing/replaced staging published a whole seal")
                    } catch PhysicalLogicWholeCandidateFlowFailure.stagingCleanup(let failure) { original = failure }
                }
                copy = original; original = nil
                do {
                    let pending = try #require(copy)
                    guard let primary = pending.primary, case .resource(let cause) = primary,
                          case WholeCandidateFlowResources.Refusal.quota = cause else {
                        throw WholeCandidateFlowFixture.Failure.mismatch("Cleanup lost the original caller cause")
                    }
                    let secondary = try #require(pending.secondary as? PhysicalLogicWholeCandidateStagingCleanupFailure.DirectoryFailure)
                    switch secondary {
                    case .missing: #expect(!replace)
                    case .replacement: #expect(replace)
                    default: throw secondary
                    }
                    let actual = probe.captured
                    #expect(pending.directory == actual.directory)
                    let saved = try #require(actual.retreat)
                    #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("fragment.cir").path))
                    let beforeRetry = resources.counts
                    cancellation.cancel()
                    #expect(beforeRetry.live > actual.fileBytes && beforeRetry.temporary == 0)
                    do {
                        try await pending.retry()
                        Issue.record("Retry accepted an absent/replaced original identity")
                    } catch let failure as PhysicalLogicWholeCandidateStagingCleanupFailure.DirectoryFailure {
                        switch failure {
                        case .missing: #expect(!replace)
                        case .replacement: #expect(replace)
                        default: throw failure
                        }
                    }
                    #expect(resources.counts.live == beforeRetry.live)
                    if replace {
                        let marker = try Data(contentsOf: pending.directory.appendingPathComponent("replacement.txt"))
                        #expect(marker == Data("owned replacement sentinel".utf8))
                    } else { #expect(!FileManager.default.fileExists(atPath: pending.directory.path)) }
                    try probe.restore()
                    try await pending.retry()
                    #expect(!FileManager.default.fileExists(atPath: pending.directory.path))
                    #expect(!FileManager.default.fileExists(atPath: saved.path))
                    let afterRetry = resources.counts
                    #expect(afterRetry.live < beforeRetry.live && afterRetry.live > 0 && afterRetry.temporary == 0)
                    #expect(beforeRetry.live - afterRetry.live == actual.fileBytes)
                    try await pending.retry()
                    #expect(resources.counts.live == afterRetry.live && resources.counts.releases == afterRetry.releases)
                    // Successful retry does not rewrite the retained original failure facts.
                    guard let primary = pending.primary, case .resource(let cause) = primary,
                          case WholeCandidateFlowResources.Refusal.quota = cause else {
                        throw WholeCandidateFlowFixture.Failure.mismatch("Retry rewrote its original primary failure")
                    }
                }
                copy = nil
                resources.expectRefund()
            } catch {
                let primary = error
                do {
                    try probe.restore()
                    if let pending = copy ?? original { try await pending.retry() }
                } catch { throw WholeCandidateFlowFixture.Failure.cleanup(primary: primary, secondary: error) }
                throw primary
            }
        }
    }
}
