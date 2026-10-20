import Foundation
import Synchronization
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpice
import CoreSpiceIO
import OSDIContracts
import OSDIRuntime
import PEXParsers
import PhysicalDesignLogicHandoff
import Testing

/// Counts the genuine public accountant's leases without substituting proof callbacks.
final class WholeCandidateFlowResources: SPICESourceResourceAccounting {
    struct Counts { var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0; var acquisitions = 0; var releases = 0 }
    private let state = Mutex(Counts())
    private let base: SPICESimulationResources
    private let onReservation: (@Sendable (SPICESourceStorageKind, UInt64) throws -> Void)?
    enum Refusal: Error { case quota; case storage }
    private enum Next { case none, quota, cancel(CancellationToken) }
    private let next = Mutex(Next.none)
    private let failStorage = Mutex(false)
    func refuseNextReservation() { failStorage.withLock { $0 = true } }
    func refuseNextCharge() { next.withLock { $0 = .quota } }
    func cancelAfterNextCharge(_ token: CancellationToken) { next.withLock { $0 = .cancel(token) } }
    init(work: UInt64 = 8_000_000_000, storage: UInt64 = 1_073_741_824,
        onReservation: (@Sendable (SPICESourceStorageKind, UInt64) throws -> Void)? = nil) throws {
        self.onReservation = onReservation
        base = try .init(maximumLiveBytes: storage, maximumTemporaryBytes: storage,
            maximumWorkUnits: work, maximumHashedBytes: 1_073_741_824)
    }
    var counts: Counts { state.withLock { $0 } }
    func checkCancellation() throws { try base.checkCancellation() }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        let action = next.withLock { action in let result = action; action = .none; return result }
        if case .quota = action { throw Refusal.quota }
        try base.charge(kind, units: units); state.withLock { $0.work += units }
        if case .cancel(let token) = action { token.cancel() }
    }
    func chargeHashedBytes(_ count: UInt64) throws { try base.chargeHashedBytes(count) }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        let refused = failStorage.withLock { value in let result = value; value = false; return result }
        if refused { throw Refusal.storage }
        let owner = try base.reserveStorage(kind: kind, byteCount: byteCount)
        state.withLock { s in
            if kind == .liveOwnedBytes { s.live += byteCount } else { s.temporary += byteCount }
            s.acquisitions += 1
        }
        let reservation = SPICESourceStorageReservation(kind: kind, byteCount: byteCount) { [self, owner] in
            state.withLock { s in
                if kind == .liveOwnedBytes { s.live -= byteCount } else { s.temporary -= byteCount }
                s.releases += 1
            }
            withExtendedLifetime(owner) {}
        }
        // Test I/O is deliberately outside the tracker mutex; a thrown callback releases this exact lease.
        try onReservation?(kind, byteCount)
        return reservation
    }
    func expectRefund(sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let c = counts
        #expect(c.live == 0 && c.temporary == 0 && c.acquisitions == c.releases, sourceLocation: sourceLocation)
    }
}

struct WholeCandidateFlowSDKFixture {
    private struct NoDependencies: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
            maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw SPICEExactSourceError.undeclaredSource(binding.key)
        }
    }
    let artifact: ArtifactAccessIntent
    let capability: ArtifactRootCapability
    let native: SPICEOSDIRuntimeInputs
    let constitutive: NativeConstitutivePreparationInputs
    let capture: OSDIConstitutiveCaptureInputs
    let range: OSDISmoothRangeCaptureInputs

    static func make(root: URL) throws -> Self {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) throws -> String {
            guard let result = env[name], !result.isEmpty else { throw WholeCandidateFlowFixture.Failure.missing(name) }
            return result
        }
        let directory = root.appendingPathComponent("sdk")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let rootID = try ArtifactRootID(rawValue: "whole-candidate-" + UUID().uuidString)
        func stage(_ path: String, _ name: String, _ expected: String) throws -> ArtifactAccessIntent {
            try FileManager.default.copyItem(atPath: path, toPath: directory.appendingPathComponent(name).path)
            let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                .init(location: .init(workspaceRelativePath: name), role: .input, kind: .model, format: .raw), relativeTo: directory)
            guard reference.digest.hexadecimalValue == expected else { throw WholeCandidateFlowFixture.Failure.mismatch(name) }
            return try .init(expectedReference: reference, availability: .local(artifactID: reference.id,
                rootID: rootID, relativePath: .init(segments: [name])), operation: .read,
                budget: .init(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
        }
        let model = try stage(value("CORESPICE_GLOBAL_CHARGE_LINEAR_LIBRARY"), "linear.osdi",
            "25f3f51c385252ce34876ca990aa6e932bf7a4c1948237b0100d03749158d846")
        let worker = try stage(value("OSDI_PRECISION_WORKER"), "worker",
            "94e44eb3aa87677877ae792fbf285f8f1ea70da3dac57446d0ec11d39df05187")
        let semantic = try value("CORESPICE_GLOBAL_CHARGE_SEMANTIC_SHA256")
        let numeric = try value("OSDI_PRECISION_NUMERIC_PROFILE_SHA256")
        guard semantic == "a85f38191b22ccf3b084f0892ee0fa51752d37f0defa6b62dee929935be35104",
              numeric == "9aa1a0cf67ead02c06ef5fdbd10ffa78ec79a2937c5b9a6d12612569fd879e59" else {
            throw WholeCandidateFlowFixture.Failure.mismatch("qualified profiles")
        }
        let capability = try ArtifactRootCapability(rootID: rootID, directoryURL: directory, digester: SHA256ContentDigester())
        let provider = try SPICEOSDILocalLibraryProvider(rootID: rootID, directoryURL: directory, intents: [model],
            stagingParentDirectory: directory, digester: SHA256ContentDigester())
        let runtime = try SPICEOSDIRuntimeInputs(provider: provider,
            loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
            evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: 4,
            maximumAdapterBytes: 16_777_216, tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12))
        let preparer = OSDINativePrecisionSessionPreparer(stagingParentDirectory: directory)
        let options = try OSDIPrecisionOptions(maximumProgramBytes: 1_048_576, maximumMappingBytes: 16_777_216,
            arenaBytes: 16_777_216, maximumWorkUnits: 100_000_000, minimumPrecisionBits: 128,
            maximumPrecisionBits: 256, startupTimeoutNanoseconds: 2_000_000_000,
            evaluationTimeoutNanoseconds: 2_000_000_000, cleanupTimeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 1_000_000)
        let profile = try ContentDigest(algorithm: .sha256, hexadecimalValue: numeric)
        return try .init(artifact: model, capability: capability, native: runtime,
            constitutive: .init(preparer: preparer, semanticProfile: .init(algorithm: .sha256, hexadecimalValue: semantic), options: options),
            capture: .init(preparer: preparer, worker: worker, source: capability, numericProfile: profile, options: options,
                coverLimits: .init(maximumSteps: 100_000, maximumGuardRecords: 100_000, maximumCopiedBytes: 10_000_000,
                    maximumCells: 100, maximumNodes: 256, maximumLeaves: 64, maximumPending: 256,
                    maximumDepth: 256, maximumIntegerBits: 1025),
                limits: .init(maximumNodes: 256, maximumAtoms: 64, maximumCoefficientBits: 4096, maximumWorkspaceBytes: 2_097_152)),
            range: .init(preparer: preparer, worker: worker, source: capability, numericProfile: profile, options: options))
    }
    func resolved() throws -> OSDIResolvedInstance {
        try .init(binding: .init(modelName: "charge", artifact: artifact.expectedReference, descriptorIndex: 0,
            expectedDescriptorName: "linear_rc", modelParameters: [
                .init(name: "conductance", scope: .model, value: .real(0)),
                .init(name: "capacitance", scope: .model, value: .real(2))]), instanceParameters: [], previousState: [])
    }
    func source(_ text: String, resources: WholeCandidateFlowResources) throws -> SPICESimulationPreparationRequest {
        let bytes = Array(text.utf8)
        let hash = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "whole-candidate-original", reference: try .init(digest: hash.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 65_536)
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "whole-candidate-fixture-v1",
            configuration: parser, resources: resources, maximumPageByteCount: 65_536)
        return try .init(root: root, environment: environment, catalog: [binding], routes: [], provider: NoDependencies(),
            configuration: parser, operatingPolicy: .recordActual,
            limits: .init(maximumElements: 4096, maximumTransformBytes: 16_777_216,
                maximumSweepPoints: 10, maximumPageByteCount: 65_536, numerical: WholeCandidateFlowFixture.numerical),
            profile: .pinnedNgspiceNormalV1, seed: 42, resolutionLimits: WholeCandidateFlowFixture.resolutionLimits(),
            osdiInstances: ["xbuf.nq": resolved()])
    }
}
