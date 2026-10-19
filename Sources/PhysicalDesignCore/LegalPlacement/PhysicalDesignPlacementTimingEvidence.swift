import CircuiteFoundation
import STAEngine
import TimingCore
import CircuiteFoundationCrypto
import Foundation

public struct PhysicalDesignPlacementTimingEvidence: Sendable, Hashable, Codable {
    public enum SelectionDisposition: String, Sendable, Hashable, Codable {
        case setupOptimization
        case baselinePreservedNoApplicableSetup
    }
    public struct RCInput: Sendable, Hashable, Codable {
        public let bytes: Data
        public let reference: ArtifactReference
    }
    public struct Candidate: Sendable, Hashable, Codable {
        public let swappedCellIDs: [String]
        public let snapshotDigest: ContentDigest
        public let timingDesign: TimingDesign
        public let timingDesignReference: ArtifactReference
        public let accepted: Bool
        public let rejection: String?
        public let result: STAExecutionResult
        public private(set) var rcInput: RCInput? = nil
    }
    public private(set) var scope: String = "characterizedPreRouteCostOnly; limitedProcessCoverage; noPhysicalSignoff"
    public private(set) var schemaVersion: Int? = nil
    public private(set) var profileContent: PhysicalDesignPlacementTimingProfile? = nil
    public private(set) var profileBytes: Data? = nil
    public private(set) var originalDesignReference: ArtifactReference? = nil
    public private(set) var sourceBindings: PhysicalDesignPlacementSourceBindings? = nil
    public private(set) var selectionDisposition: SelectionDisposition? = nil
    public let model: String
    public let profile: PhysicalDesignPlacementTimingReference
    public let candidates: [Candidate]
    public let selectedCandidateIndex: Int
    public let candidateChecks: Int
    public let candidateCeiling: Int
    public let structuralCeiling: Int
    public let chargedWorkUnits: UInt64

    public func requireSelectedGeometry(_ snapshot: PhysicalDesignSnapshot) throws {
        let sequential = schemaVersion == 2
        guard scope == (sequential ? Self.sequentialScope : "characterizedPreRouteCostOnly; limitedProcessCoverage; noPhysicalSignoff"),
              candidates.indices.contains(selectedCandidateIndex), candidates[selectedCandidateIndex].accepted,
              candidates[selectedCandidateIndex].snapshotDigest == (try Self.geometryDigest(snapshot)),
              candidates[selectedCandidateIndex].result.status == .completed else {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("Retained placement timing does not bind the selected geometry")
        }
        let selected = candidates[selectedCandidateIndex]
        if !sequential {
            guard selected.result.payload.worstSetupSlack?.isFinite == true else {
                throw PhysicalDesignPlacementTimingError.unavailableTiming("Retained legacy setup slack is unavailable")
            }
            try Self.requireGraphReference(selected)
        }
        if sequential {
            guard let content = profileContent, content.isSourceBoundSequential,
                  let originalDesignReference, originalDesignReference.descriptor.kind == .netlist,
                  let bindings = sourceBindings, bindings.schemaVersion == 1,
                  content.manifest == snapshot.processManifest else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Retained sequential profile or source classification is missing")
            }
            guard let profileBytes,
                  (try PhysicalDesignJSONCodec().decode(PhysicalDesignPlacementTimingProfile.self, from: profileBytes)) == content else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Retained placement profile bytes differ from their decoded contract")
            }
            guard profile.artifact.reference.byteCount == UInt64(profileBytes.count),
                  profile.artifact.reference.digest == (try SHA256ContentDigester().digest(data: profileBytes, using: .sha256)) else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Retained placement profile differs from its exact input")
            }
            for candidate in candidates {
                try Self.requireGraphReference(candidate)
                _ = try Self.setupMetric(candidate.result)
                guard let rc = candidate.rcInput, rc.reference.byteCount == UInt64(rc.bytes.count),
                      rc.reference.digest == (try SHA256ContentDigester().digest(data: rc.bytes, using: .sha256)),
                      candidate.result.inputBindings.contains(where: { $0.reference == rc.reference }) else {
                    throw PhysicalDesignPlacementTimingError.logicalMismatch("Retained candidate RC differs from its exact STA input")
                }
                let rejection = try Self.nonSetupRejection(candidate.result, profile: content)
                guard !candidate.accepted || rejection == nil else {
                    throw PhysicalDesignPlacementTimingError.unavailableTiming("Retained adopted candidate fails required non-setup checks")
                }
            }
            for binding in bindings.terminals where binding.coverage == .boundSignal || binding.coverage == .boundSupply {
                guard let id = binding.physicalPinID, let pin = snapshot.pins.first(where: { $0.id == id }),
                      pin.cellID == binding.instanceID, pin.name == binding.pinName,
                      pin.netID == binding.netID, pin.direction == binding.direction,
                      binding.instanceID == nil || snapshot.cells.contains(where: { $0.id == binding.instanceID && $0.master == binding.masterName }) else {
                    throw PhysicalDesignPlacementTimingError.logicalMismatch("Retained source terminal differs from the selected physical identity")
                }
            }
            if let slack = try Self.setupMetric(selected.result) {
                guard selectionDisposition == .setupOptimization,
                      slack >= max(0, content.minimumSetupSlackSeconds ?? 0) else {
                    throw PhysicalDesignPlacementTimingError.unavailableTiming("Retained selected setup slack fails schema-two admission")
                }
            } else {
                guard content.minimumSetupSlackSeconds == nil else {
                    throw PhysicalDesignPlacementTimingError.unavailableTiming("An explicit setup minimum requires a finite measured metric")
                }
                guard selectionDisposition == .baselinePreservedNoApplicableSetup,
                      selectedCandidateIndex == 0, candidates.count == 1, selected.swappedCellIDs.isEmpty else {
                    throw PhysicalDesignPlacementTimingError.logicalMismatch("Nonapplicable setup must preserve the sole baseline candidate")
                }
            }
        } else if schemaVersion != nil || profileContent != nil || profileBytes != nil || originalDesignReference != nil || sourceBindings != nil
                    || selectionDisposition != nil
                    || candidates.contains(where: { $0.rcInput != nil }) {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("Legacy placement evidence cannot grant sequential source coverage")
        }
    }

    private static func requireGraphReference(_ candidate: Candidate) throws {
        let bytes = try PhysicalDesignJSONCodec().encode(candidate.timingDesign)
        guard candidate.timingDesignReference.byteCount == UInt64(bytes.count),
              candidate.timingDesignReference.digest == (try SHA256ContentDigester().digest(data: bytes, using: .sha256)),
              candidate.result.inputBindings.contains(where: { $0.reference == candidate.timingDesignReference }) else {
            throw PhysicalDesignPlacementTimingError.logicalMismatch("Retained placement STA does not bind its exact projected graph")
        }
    }

    static let sequentialScope = "sourceBoundSequentialPreRouteRCOnly; sourcePropagatedPrimaryClock; noPostRouteClosure; noPhysicalSignoff"

    /// Creation consumes this only after prepared validation; a missing metric never implies source nonapplicability.
    static func setupMetric(_ result: STAExecutionResult) throws -> Double? {
        switch result.payload.setupApplicability {
        case .measured:
            guard let slack = result.payload.worstSetupSlack, slack.isFinite else {
                throw PhysicalDesignPlacementTimingError.unavailableTiming("Measured setup has no finite metric")
            }
            return slack
        case .sourceNotApplicable:
            guard result.payload.worstSetupSlack == nil else {
                throw PhysicalDesignPlacementTimingError.unavailableTiming("Nonapplicable setup cannot carry a numerical slack")
            }
            return nil
        case .unknown, nil:
            throw PhysicalDesignPlacementTimingError.unavailableTiming("Setup applicability is unknown or missing")
        }
    }

    /// Creation calls this only after exact prepared-owner validation; reload checks structural policy, not qualification.
    static func nonSetupRejection(_ result: STAExecutionResult, profile: PhysicalDesignPlacementTimingProfile,
                                  budget: NativePhysicalDesignPlacementTimingBudget? = nil) throws -> String? {
        guard result.status == .completed, result.payload.unconstrainedEndpoints.isEmpty,
              let evidence = result.payload.sourceEvidence,
              let configuration = result.payload.effectiveConfiguration,
              configuration.requireStrictSourceEvidence,
              evidence.configurationDigest == configuration.digest,
              configuration.distributedRC == profile.distributedRC,
              Set(configuration.operatingSupplyAssumptions) == Set(profile.operatingSupplyAssumptions ?? []),
              !configuration.clockReceiverScope.isEmpty,
              !result.payload.clockObservations.isEmpty,
              configuration.clockSources.values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isPropagated) }),
              !result.payload.wireCoverage.contains(where: { $0.model == .idealClock || $0.model == .uncovered }) else {
            throw PhysicalDesignPlacementTimingError.unavailableTiming("Sequential placement lacks exact strict source/RC/propagated-clock coverage")
        }
        let roleCount = UInt64(evidence.roles.count)
        let square = roleCount.multipliedReportingOverflow(by: roleCount)
        let joins = roleCount.multipliedReportingOverflow(by: UInt64(result.payload.endpoints.count))
        let doubled = square.partialValue.multipliedReportingOverflow(by: 2)
        let total = doubled.partialValue.addingReportingOverflow(joins.partialValue)
        let linearRoles = roleCount.multipliedReportingOverflow(by: 3)
        guard !square.overflow, !joins.overflow, !doubled.overflow, !total.overflow, !linearRoles.overflow else {
            throw PhysicalDesignPlacementTimingError.resourceLimit("Source check policy size overflow")
        }
        var work = total.partialValue
        for count in [linearRoles.partialValue, UInt64(evidence.coverage.count),
                      UInt64(result.payload.endpoints.count), UInt64(result.payload.criticalPaths.count), 1] {
            let next = work.addingReportingOverflow(count)
            guard !next.overflow else {
                throw PhysicalDesignPlacementTimingError.resourceLimit("Source applicability work size overflow")
            }
            work = next.partialValue
        }
        try budget?.chargeWork(work)
        do { try result.payload.validateSetupApplicabilityStructure() }
        catch {
            switch error {
            case .capacity:
                throw PhysicalDesignPlacementTimingError.resourceLimit("Source setup applicability exceeds its retained execution limits")
            case .invalidStructure:
                throw PhysicalDesignPlacementTimingError.unavailableTiming("Source setup applicability contradicts its retained measurements or dispositions")
            }
        }
        var rejection: String?
        for role in evidence.roles {
            try budget?.check()
            guard role.library == profile.library.reference else {
                throw PhysicalDesignPlacementTimingError.logicalMismatch("Source role uses a different characterized library")
            }
            guard let kind = role.analysisKind else { continue }
            guard let status = evidence.checkStatus(for: role) else {
                throw PhysicalDesignPlacementTimingError.unavailableTiming("Required source check has no disposition")
            }
            if status == .staticDataNotApplicable {
                guard kind == .setup || kind == .hold else {
                    throw PhysicalDesignPlacementTimingError.unavailableTiming("Static data cannot remove a control timing check")
                }
                continue
            }
            if status == .sourceNotApplicable || status == .staticControlNotApplicable || status == .staticStateNotApplicable {
                continue
            }
            guard status == .measured, let key = role.endpointKey,
                  let endpoint = result.payload.endpoints.first(where: {
                      $0.modeID == role.modeID && $0.cornerID == role.cornerID && $0.endpoint == key
                  }) else {
                throw PhysicalDesignPlacementTimingError.unavailableTiming("Required source check is excluded, unrequested, unconnected or unknown")
            }
            let slack = checkSlack(endpoint, kind: kind)
            guard let slack, slack.isFinite else {
                throw PhysicalDesignPlacementTimingError.unavailableTiming("Required source check has no finite measured slack")
            }
            if kind != .setup && slack < 0 { rejection = "Required \(kind.rawValue) check failed at \(key)" }
        }
        for endpoint in result.payload.endpoints {
            try budget?.chargeWork(1)
            guard endpoint.excludedChecks?.isEmpty != false, endpoint.unconstrainedChecks?.isEmpty != false else {
                throw PhysicalDesignPlacementTimingError.unavailableTiming("A placement endpoint has excluded or unconstrained checks")
            }
            for kind in [STAAnalysisKind.hold, .recovery, .removal, .pulseWidth] {
                if let slack = checkSlack(endpoint, kind: kind) {
                    guard slack.isFinite else { throw PhysicalDesignPlacementTimingError.unavailableTiming("A non-setup endpoint slack is not finite") }
                    if slack < 0 { rejection = "Required \(kind.rawValue) check failed at \(endpoint.endpoint)" }
                }
            }
        }
        return rejection
    }

    private static func checkSlack(_ endpoint: STAEndpoint, kind: STAAnalysisKind) -> Double? {
        switch kind {
        case .setup: endpoint.setupSlack
        case .hold: endpoint.holdSlack
        case .recovery: endpoint.recoverySlack
        case .removal: endpoint.removalSlack
        case .pulseWidth: endpoint.pulseWidthSlack
        }
    }
    static func geometryDigest(_ snapshot: PhysicalDesignSnapshot) throws -> ContentDigest {
        struct Geometry: Encodable {
            let topCell: String
            let unitsPerMicron: Int
            let die: PhysicalDesignSnapshot.Rect?
            let core: PhysicalDesignSnapshot.Rect?
            let rows: [PhysicalDesignSnapshot.Row]
            let cells: [PhysicalDesignSnapshot.Cell]
            let pins: [PhysicalDesignSnapshot.Pin]
            let nets: [PhysicalDesignSnapshot.Net]
            let blockages: [PhysicalDesignSnapshot.Rect]
            let processManifest: ArtifactReference?
            let processAssets: [String: ArtifactReference]
        }
        let geometry = Geometry(topCell: snapshot.topCell, unitsPerMicron: snapshot.unitsPerMicron,
            die: snapshot.die, core: snapshot.core, rows: snapshot.rows, cells: snapshot.cells, pins: snapshot.pins,
            nets: snapshot.nets, blockages: snapshot.blockages, processManifest: snapshot.processManifest, processAssets: snapshot.processAssets)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try SHA256ContentDigester().digest(data: encoder.encode(geometry), using: .sha256)
    }
}
