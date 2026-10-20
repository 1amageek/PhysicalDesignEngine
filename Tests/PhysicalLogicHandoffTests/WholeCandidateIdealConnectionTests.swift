import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceIO
import PEXParsers
import PhysicalDesignCore
import Testing
@testable import PhysicalDesignLogicHandoff

@Suite("Declared SPEF ideal connections", .timeLimit(.minutes(2)))
struct WholeCandidateIdealConnectionTests {
    private struct NoDependencies: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
            maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw SPICEExactSourceError.undeclaredSource(binding.key)
        }
    }
    private let text = """
    Declared ideal connection RC
    VIN p 0 0
    Rdrive p a 2
    Cstate d 0 2
    XPEX_whole a d whole_pex
    .subckt whole_pex A D
    Rcontact A D 0
    .ends whole_pex
    .tran 1p 1
    .end
    """
    private func source(_ text: String, resources: WholeCandidateFlowResources) async throws -> PreparedSPICESimulation {
        let bytes = Array(text.utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "ideal-connection-source", reference: try .init(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 65_536)
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "ideal-connection-test-v1",
            configuration: parser, resources: resources, maximumPageByteCount: 65_536)
        let request = try SPICESimulationPreparationRequest(root: root, environment: environment, catalog: [binding], routes: [],
            provider: NoDependencies(), configuration: parser, operatingPolicy: .recordActual,
            limits: .init(maximumElements: 4096, maximumTransformBytes: 16_777_216, maximumSweepPoints: 10,
                maximumPageByteCount: 65_536, numerical: WholeCandidateFlowFixture.numerical),
            profile: .pinnedNgspiceNormalV1, seed: 42, resolutionLimits: WholeCandidateFlowFixture.resolutionLimits())
        return try await SPICESimulationPreparer().prepare(request, resources: resources)
    }
    private func proposal(_ source: PreparedSPICESimulation) throws -> NativePrescribedVoltageFlowRequest {
        let n = source.circuit.nodes.count - 1 + source.circuit.branches.count + 1
        let selected = try #require(source.circuit.instances.firstIndex { $0.name.lowercased() == "vin" })
        let zero = try CompensatedValue(high: 0)
        let inverse = try SparseStructure(dimension: 1, rowPointers: [0,1], columnIndices: [0])
        return try .init(originalLower: [CompensatedValue](repeating: .init(high: -10), count: n),
            originalUpper: [CompensatedValue](repeating: .init(high: 10), count: n), startTime: zero,
            duration: .init(high: 0.125), sources: [.init(deviceIndex: selected, zeroVoltage: 0, oneVoltage: 1,
                timeOrigin: 0, timeScale: 1, initialNormalized: 1...1, normalized: 1...1, normalizedDerivativePerSecond: 0...0)],
            algebraicRows: [], dynamicInitialCoordinates: [WholeCandidateFlowFixture.ce(0.499,0.501)],
            initial: .init(coordinates: [WholeCandidateFlowFixture.ce(0.48,0.52)], center: [.init(high: 0.5)],
                inverse: inverse, inverseValues: [1]), chargeBox: [WholeCandidateFlowFixture.ce(0.9,1.15)],
            window: .init(coordinates: [WholeCandidateFlowFixture.ce(0.4,0.6)], center: [.init(high: 0.5)],
                inverse: inverse, inverseValues: [0.5]))
    }
    private func tightProposal(_ source: PreparedSPICESimulation) throws -> NativePrescribedVoltageFlowRequest {
        let request = try proposal(source), topology = MatrixTopology(ir: source.circuit)
        var lower = request.originalLower, upper = request.originalUpper
        for (node,name) in source.circuit.nodeNames where node != .ground {
            let row = try #require(topology.nodeIndex(node))
            lower[row] = try .init(high: name.lowercased() == "p" ? 0.95 : 0.35)
            upper[row] = try .init(high: name.lowercased() == "p" ? 1.05 : 0.65)
        }
        return .init(originalLower: lower, originalUpper: upper, startTime: request.startTime, duration: request.duration,
            sources: request.sources, algebraicRows: request.algebraicRows, dynamicInitialCoordinates: request.dynamicInitialCoordinates,
            initial: request.initial, chargeBox: request.chargeBox, window: request.window)
    }
    @Test func actualPreparedPrimitiveRetainsBothNodesAndNonzeroCurrentChargeLaw() async throws {
        let resources = try WholeCandidateFlowResources()
        do {
            let source = try await source(text, resources: resources)
            let control = try PhysicalLogicWholeCandidateControl.make(resources: resources, cancellation: .init(), limits: WholeCandidateFlowFixture.limits())
            let requested = try tightProposal(source)
            let preparedConnection = try PhysicalLogicWholeCandidateIdealConnections.prepare(source: source, flow: requested, control: control)
            let connection = try #require(preparedConnection)
            #expect(connection.rows.count == 1 && connection.circuit.nodes == source.circuit.nodes)
            let row = connection.rows[0], old = source.circuit.instances[row.instanceIndex], transformed = connection.circuit.instances[row.instanceIndex]
            #expect(old.typeName == "resistor" && transformed.typeName == "vsource" && old.nodes == transformed.nodes)
            #expect(old.nodes[0] != old.nodes[1] && transformed.ownedBranches == [row.branch])
            let conditions = try source.configuration.options.operatingConditions()
            let circuit = try NativeCircuitPreparer().prepareNativeConstitutive(ir: connection.circuit, registry: .standard(),
                operatingConditions: conditions, limits: WholeCandidateFlowFixture.limits().native,
                numericalLimits: source.configuration.numericalLimits, resources: control, cancellation: control.cancellation)
            try circuit.withIndependentVoltageSources(cancellation: .init()) { view in
                var count = 0
                for fact in view.sources { if try connection.validate(fact, control: control) { count += 1 } }
                #expect(count == 1 && view.preparation.plan.topology.variableMap[.branchCurrent(row.branch)] != nil)
            }
            let flow = try await circuit.certifyPrescribedVoltageFlow(request: connection.request, capture: nil, range: nil,
                limits: WholeCandidateFlowFixture.flowLimits, cancellation: .init())
            WholeCandidateFlowFixture.contains(try flow.selectedCurrentAlmostEverywhere(at: 1), 0.25)
            let current = try flow.selectedCurrentAlmostEverywhere(at: 1)
            #expect(current.center.bounds.lower - current.radius > 0)
            WholeCandidateFlowFixture.contains(try flow.chargeRateAlmostEverywhere(at: 0), 0.25)
            let pairs = [NativePrescribedVoltageFlowVoltagePair(positive: old.nodes[0], reference: .ground),
                .init(positive: old.nodes[1], reference: .ground)]
            let observations = try flow.observeVoltages(pairs: pairs.span, limits: WholeCandidateFlowFixture.limits().observations, cancellation: .init())
            let first = try observations.observation(at: 0), second = try observations.observation(at: 1)
            // The ideal law equates physical values, not independently rounded CE representations.
            // R=2,C=2: d'=a'=(1-.5)/4=.125 and a(h)=d(h)=1-.5*exp(-h/4).
            let endpoint = 1 - 0.5 * exp(-connection.request.duration.high / 4)
            for observation in [first, second] {
                WholeCandidateFlowFixture.contains(observation.initialVoltage, 0.5)
                WholeCandidateFlowFixture.contains(observation.windowVoltage, 0.5)
                WholeCandidateFlowFixture.contains(observation.windowVoltage, endpoint)
                WholeCandidateFlowFixture.contains(observation.almostEverywhereRate, 0.125)
                #expect(observation.almostEverywhereRate.absoluteUpperBound < 0.2)
            }
            try flow.withScope { scope in
                let validatedCount = try connection.validate(scope.sources, control: control)
                #expect(validatedCount == 1)
            }
            try circuit.close()
        }
        resources.expectRefund()
    }
    @Test func exactPositiveZeroAndDistinctEndpointsAreRequiredWithoutChangingPositiveResistors() async throws {
        let resources = try WholeCandidateFlowResources()
        do {
            let positive = try await source(text.replacingOccurrences(of: "Rcontact A D 0", with: "Rcontact A D 1"), resources: resources)
            let control = try PhysicalLogicWholeCandidateControl.make(resources: resources, cancellation: .init(), limits: WholeCandidateFlowFixture.limits())
            let positiveProposal = try proposal(positive)
            let unchanged = try PhysicalLogicWholeCandidateIdealConnections.prepare(source: positive, flow: positiveProposal, control: control)
            #expect(unchanged == nil)
            for changed in [text.replacingOccurrences(of: "Rcontact A D 0", with: "Rcontact A D -0"),
                text.replacingOccurrences(of: "Rcontact A D 0", with: "Rcontact A A 0")] {
                let prepared = try await source(changed, resources: resources)
                do { _ = try PhysicalLogicWholeCandidateIdealConnections.prepare(source: prepared, flow: proposal(prepared), control: control)
                    Issue.record("Unsupported zero-resistance form was silently interpreted") }
                catch PhysicalLogicWholeCandidateFlowFailure.parasitics {}
            }
        }
        resources.expectRefund()
    }
    @Test func sameControlRefusalCancellationAndLastMappingCopyRelease() async throws {
        let resources = try WholeCandidateFlowResources()
        do {
            let source = try await source(text, resources: resources), proposal = try proposal(source)
            let token = CancellationToken()
            let control = try PhysicalLogicWholeCandidateControl.make(resources: resources, cancellation: token, limits: WholeCandidateFlowFixture.limits())
            let baseline = resources.counts
            resources.refuseNextReservation()
            do { _ = try PhysicalLogicWholeCandidateIdealConnections.prepare(source: source, flow: proposal, control: control); Issue.record("Storage refusal ignored") }
            catch PhysicalLogicWholeCandidateFlowFailure.resource {}
            resources.refuseNextCharge()
            do { _ = try PhysicalLogicWholeCandidateIdealConnections.prepare(source: source, flow: proposal, control: control); Issue.record("Work refusal ignored") }
            catch PhysicalLogicWholeCandidateFlowFailure.resource {}
            resources.cancelAfterNextCharge(token)
            do { _ = try PhysicalLogicWholeCandidateIdealConnections.prepare(source: source, flow: proposal, control: control); Issue.record("Cancellation ignored") }
            catch PhysicalLogicWholeCandidateFlowFailure.cancelled {}
            #expect(resources.counts.live == baseline.live && resources.counts.temporary == baseline.temporary)
            let fresh = try PhysicalLogicWholeCandidateControl.make(resources: resources, cancellation: .init(), limits: WholeCandidateFlowFixture.limits())
            var original = try PhysicalLogicWholeCandidateIdealConnections.prepare(source: source, flow: proposal, control: fresh)
            let retained = resources.counts.live
            var copy = original; original = nil
            #expect(copy?.rows.count == 1 && resources.counts.live == retained)
            copy = nil
            #expect(resources.counts.live < retained)
        }
        resources.expectRefund()
    }
    /// Hints are explicit proposals for the FINAL Native dimension; production never fills them in.
    private func wholeProposal(_ f: WholeCandidateFlowFixture, sdk: WholeCandidateFlowSDKFixture,
        resources: WholeCandidateFlowResources) async throws -> NativePrescribedVoltageFlowRequest {
        let draft = try await f.flow(sdk: sdk)
        let composed = try PEXSPICEBackannotationComposer(options: .init(topCell: nil,
            subcircuitName: "whole_pex", instanceName: "XPEX_whole", requirePortMatches: true))
            .compose(sourceNetlist: WholeCandidateFlowFixture.source, ir: f.ir)
        let preparation = try sdk.source(composed, resources: resources)
        let source = try await SPICESimulationPreparer().prepare(preparation, resources: resources)
        let control = try PhysicalLogicWholeCandidateControl.make(resources: resources, cancellation: .init(), limits: WholeCandidateFlowFixture.limits())
        let preparedConnections = try PhysicalLogicWholeCandidateIdealConnections.prepare(source: source, flow: draft, control: control)
        let connections = try #require(preparedConnections)
        #expect(connections.rows.count == 1)
        let ir = connections.circuit, topology = MatrixTopology(ir: ir)
        func node(_ name: String) throws -> Node {
            try #require(ir.nodeNames.first { $0.value.lowercased() == name.lowercased() }?.key)
        }
        let input = try node("a"), contact = try node("new-buffer:A"), vdd = try node("vdd"),
            y = try node("new-buffer:Y"), output = try node("y")
        let vin = ir.instances[draft.sources[0].deviceIndex]
        let supply = try #require(ir.instances.first { $0.name.lowercased() == "vdd" })
        let inputBranch = try #require(vin.ownedBranches.first)
        let excluded = [try #require(topology.nodeIndex(input)), try #require(topology.nodeIndex(contact)),
            try #require(topology.variableIndex(for: .branchCurrent(inputBranch))),
            try #require(topology.variableIndex(for: .branchCurrent(connections.rows[0].branch)))]
        let free = (0..<topology.dimension).filter { !excluded.contains($0) }
        #expect(free.count == 4 && topology.dimension == draft.originalLower.count + 1)
        func reduced(_ node: Node) throws -> Int {
            let row = try #require(topology.nodeIndex(node))
            return try #require(free.firstIndex(of: row))
        }
        let v = try reduced(vdd), yi = try reduced(y), oi = try reduced(output)
        let supplyBranch = try #require(supply.ownedBranches.first)
        let supplyRow = try #require(topology.variableIndex(for: .branchCurrent(supplyBranch)))
        let si = try #require(free.firstIndex(of: supplyRow)), algebraic = free.indices.filter { $0 != yi }
        func equation(_ coordinate: Int) throws -> Int { try #require(algebraic.firstIndex(of: coordinate)) + 1 }
        func inverse(_ dynamic: Double) throws -> (SparseStructure, [Double]) {
            // H=(3Y-q, Idd, O-Y, Vdd-1), up to the actual checked row order.
            var rows = [[(Int,Double)]](repeating: [], count: free.count)
            rows[yi] = [(0,dynamic)]; rows[oi] = [(0,dynamic),(try equation(oi),1)]
            rows[v] = [(try equation(si),1)]; rows[si] = [(try equation(v),1)]
            var pointers = [0], columns: [Int] = [], values: [Double] = []
            for row in rows {
                for (column,value) in row.sorted(by: { $0.0 < $1.0 }) { columns.append(column); values.append(value) }
                pointers.append(columns.count)
            }
            return (try .init(dimension: free.count, rowPointers: pointers, columnIndices: columns),values)
        }
        var lo = [Double](repeating: -2, count: topology.dimension), hi = [Double](repeating: 2, count: topology.dimension)
        for n in [input,contact] { let row = try #require(topology.nodeIndex(n)); lo[row] = -0.1; hi[row] = 1.1 }
        let vddRow = try #require(topology.nodeIndex(vdd)); lo[vddRow] = 0.9; hi[vddRow] = 1.1
        for n in [y,output] { let row = try #require(topology.nodeIndex(n)); lo[row] = -0.2; hi[row] = 1.2 }
        var center = [Double](repeating: 0, count: free.count); center[v] = 1; center[yi] = 0.5; center[oi] = 0.5
        var initial = try center.map { try WholeCandidateFlowFixture.ce($0-0.05,$0+0.05) }, window = initial
        initial[yi] = try WholeCandidateFlowFixture.ce(0.49,0.51); initial[oi] = try WholeCandidateFlowFixture.ce(0.45,0.55)
        window[yi] = try WholeCandidateFlowFixture.ce(0.2,0.8); window[oi] = try WholeCandidateFlowFixture.ce(0.1,0.9)
        let first = try inverse(1), slab = try inverse(1.0/3)
        return try .init(originalLower: lo.map { try .init(high: $0) }, originalUpper: hi.map { try .init(high: $0) },
            startTime: draft.startTime, duration: draft.duration, sources: draft.sources, algebraicRows: algebraic,
            dynamicInitialCoordinates: draft.dynamicInitialCoordinates,
            initial: .init(coordinates: initial, center: center.map { try .init(high: $0) }, inverse: first.0, inverseValues: first.1),
            chargeBox: draft.chargeBox,
            window: .init(coordinates: window, center: center.map { try .init(high: $0) }, inverse: slab.0, inverseValues: slab.1))
    }
    @Test func actualWholeCandidateKeepsRawPinsAndColdZeroWhilePreparingSelectedNativeEquation() async throws {
        let root = try PhysicalLogicHandoffTests().temporary()
        do {
            let f = try await WholeCandidateFlowFixture.make(root: root, zeroInputContact: true)
            let sdk = try WholeCandidateFlowSDKFixture.make(root: root)
            do {
                // Persist/reload this SAME R0 candidate and reread its exact captured SPEF.
                // A decoded live Flow owner is deliberately not constructed.
                let store = FileSystemPhysicalDesignArtifactStore(projectRoot: f.root)
                let persistence = NativePhysicalLogicCheckedCandidatePersistence()
                let savedLayout = try await store.write(PhysicalDesignJSONCodec().encode(f.assessment.candidate),
                    logicalID: "contact-candidate", relativePath: "contact-candidate.json", kind: .layout, format: .json, runID: "contact-flow")
                var write = try WholeCandidateFlowFixture.context()
                let artifacts = try await persistence.persist(f.assessment,
                    candidateReference: .init(layoutArtifact: savedLayout, topCell: "top",
                        layoutDigest: savedLayout.reference.digest.hexadecimalValue), store: store,
                    runID: "contact-flow", relativeDirectory: "contact-saved", limits: WholeCandidateFlowFixture.handoffLimits(),
                    maximumArtifactBytes: 8_388_608, context: &write)
                let record = try JSONDecoder().decode(PhysicalLogicCheckedCandidateArtifacts.self, from: JSONEncoder().encode(artifacts))
                var read = try WholeCandidateFlowFixture.context()
                let reloaded = try await persistence.reload(record, baseline: f.baseline,
                    store: FileSystemPhysicalDesignArtifactStore(projectRoot: f.root), limits: WholeCandidateFlowFixture.handoffLimits(),
                    maximumArtifactBytes: 8_388_608, context: &read)
                try reloaded.requireBinding(to: f.assessment.candidate)
                let rereadSPEF = try Data(contentsOf: f.root.appendingPathComponent("candidate.spef"))
                #expect(rereadSPEF == f.spef)
                #expect(f.ir.elements.contains { $0.kind == .resistor && $0.value.bitPattern == 0 && $0.nodeB != $0.nodeA })
                let resources = try WholeCandidateFlowResources()
                do {
                    let proposal = try await wholeProposal(f, sdk: sdk, resources: resources)
                    let request = try await f.request(sdk: sdk, resources: resources, flow: proposal, spefBytes: rereadSPEF)
                    var context = try WholeCandidateFlowFixture.context()
                    var original: PhysicalLogicWholeCandidateFlow? = try await reloaded.certifyWholeCandidateFlow(preparedSTA: f.prepared,
                        request: request, limits: WholeCandidateFlowFixture.limits(), context: &context, resources: resources, cancellation: .init())
                    var copy = original; original = nil
                    do {
                        let result = try #require(copy)
                        let zero = try #require(result.sourcePreparation.circuit.instances.first {
                            guard $0.typeName == "resistor", case .real(let resistance) = $0.parameters["r"] else { return false }
                            return resistance.bitPattern == 0
                        })
                        #expect(zero.nodes.count == 2 && zero.nodes[0] != zero.nodes[1])
                        try result.observations.flow.withScope { scope in
                            var contactIndex: Int?
                            for index in scope.sources.indices where scope.sources[index].fact.instance.name == zero.name { contactIndex = index }
                            let actual = scope.sources[try #require(contactIndex)]
                            #expect(actual.fact.instance.nodes == zero.nodes && actual.fact.dcVoltage.bitPattern == 0)
                            #expect(actual.assumptions.zeroVoltage.bitPattern == 0 && actual.assumptions.oneVoltage.bitPattern == 0)
                            #expect(scope.sources.count == 2 && scope.models.count == 1)
                            #expect(scope.preparation.plan.topology.dimension == proposal.originalLower.count)
                        }
                        // R=2, total C=3: full AC family includes constant U=0/1 and Y' = +/-1/12 at Y=.5.
                        let output = try #require(result.timingContext.record.sources.firstIndex { $0.origin == .prescribedCellOutput })
                        let observation = try result.observations.observation(at: output)
                        WholeCandidateFlowFixture.contains(observation.almostEverywhereRate, -1.0/12)
                        WholeCandidateFlowFixture.contains(observation.almostEverywhereRate, 1.0/12)
                        WholeCandidateFlowFixture.contains(try result.observations.flow.selectedCurrentAlmostEverywhere(at: 1), -0.25)
                        WholeCandidateFlowFixture.contains(try result.observations.flow.selectedCurrentAlmostEverywhere(at: 1), 0.25)
                        #expect(result.jointSlices.contains { $0.windowValue == 0...1 && $0.almostEverywhereSlope.contains(0) })
                        #expect(resources.counts.live > 0)
                    }
                    copy = nil
                    // The original-dimension proposal is refused rather than extended with invented current bounds.
                    let oldProposal = try await f.flow(sdk: sdk)
                    let oldRequest = try await f.request(sdk: sdk, resources: resources, flow: oldProposal)
                    var other = try WholeCandidateFlowFixture.context()
                    do {
                        _ = try await reloaded.certifyWholeCandidateFlow(preparedSTA: f.prepared, request: oldRequest,
                            limits: WholeCandidateFlowFixture.limits(), context: &other, resources: resources, cancellation: .init())
                        Issue.record("A missing final branch domain was invented")
                    } catch PhysicalLogicWholeCandidateFlowFailure.native(let cause) {
                        guard case NativePrescribedVoltageFlowFailure.invalidInput = cause else { throw cause }
                    }
                }
                resources.expectRefund()
            } catch {
                let primary = error
                do { try await sdk.capability.close().wait() }
                catch { throw WholeCandidateFlowFixture.Failure.cleanup(primary: primary, secondary: error) }
                throw primary
            }
            try await sdk.capability.close().wait()
            try FileManager.default.removeItem(at: root)
        } catch {
            let primary = error
            do { try FileManager.default.removeItem(at: root) }
            catch { throw WholeCandidateFlowFixture.Failure.cleanup(primary: primary, secondary: error) }
            throw primary
        }
    }

}
