import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import PEXCore
import PEXParsers
import STAEngine

/// Transfers exact controlled PEX output into a separately accounted Core source owner.
internal enum PhysicalLogicWholeCandidateComposition {
    static func prepare(assessment: PhysicalLogicECOAssessment, preparedSTA: PreparedSTAExecution,
        request: PhysicalLogicWholeCandidateFlowRequest, control: PhysicalLogicWholeCandidateControl)
        async throws -> PreparedSPICESimulation {
        try control.check()
        guard preparedSTA.request.parasitics?.reference == request.spefReference,
              UInt64(request.spefBytes.count) == request.spefReference.byteCount,
              UInt64(request.spefBytes.count) <= control.limits.maximumSPEFBytes else {
            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Captured SPEF differs from actual STA artifact")
        }
        guard request.source.root.isInvocationAccounted else {
            throw PhysicalLogicWholeCandidateFlowFailure.source("Original source is not invocation-accounted")
        }
        let byteLease = try control.slots(UInt8.self, count: request.spefBytes.count)
        defer { withExtendedLifetime(byteLease) {} }
        let rawSPEF = try copy(request.spefBytes, control: control)
        let hashLease = try control.reserve(try PhysicalLogicWholeCandidateControl.sum(
            UInt64(MemoryLayout<ContentDigestResult>.stride), 64))
        defer { withExtendedLifetime(hashLease) {} }
        let spefHash = try digest(rawSPEF, pageByteCount: request.source.limits.maximumPageByteCount, control: control)
        guard spefHash.digest == request.spefReference.digest else {
            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Captured SPEF digest differs from actual STA artifact")
        }
        let spefTextLease = try control.reserve(try textBytes(request.spefBytes.count))
        let originalTextLease = try control.reserve(try textBytes(request.source.root.bytes.count))
        defer { withExtendedLifetime((spefTextLease, originalTextLease)) {} }
        try control.check(UInt64(request.spefBytes.count))
        guard let spef = String(bytes: rawSPEF, encoding: .utf8) else {
            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("SPEF is not UTF-8")
        }
        try control.check(UInt64(request.source.root.bytes.count))
        guard let original = String(data: request.source.root.bytes, encoding: .utf8) else {
            throw PhysicalLogicWholeCandidateFlowFailure.source("Original root is not UTF-8")
        }
        try control.check()
        let adapter = PEXControl(owner: control)
        let lexed: (value: [SPEFToken.Located], retention: PEXParserRetention)
        let parsed: (value: SPEFParseTree, retention: PEXParserRetention)
        let lowered: (value: ParasiticIR, retention: PEXParserRetention)
        let fragment: (value: String, retention: PEXParserRetention)
        do {
            lexed = try SPEFLexer.tokenize(source: spef, fileName: nil, control: adapter)
            parsed = try SPEFParser().parse(tokens: lexed.value, control: adapter)
            lowered = try SPEFLowering().lower(parsed.value, cornerID: request.pexCorner, control: adapter)
            try PhysicalLogicWholeCandidatePEXMembership.validate(lowered.value, assessment: assessment, request: request, control: control)
            fragment = try PEXSPICEWriter(options: .init(subcircuitName: "whole_pex")).write(lowered.value, control: adapter)
        } catch { throw pexFailure(error) }
        defer { withExtendedLifetime((lexed.retention, parsed.retention, lowered.retention, fragment.retention)) {} }
        guard UInt64(fragment.value.utf8.count) <= control.limits.maximumComposedBytes else {
            throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Generated PEX fragment exceeds output ceiling")
        }
        let staging: PhysicalLogicWholeCandidateStaging
        do { staging = try await PhysicalLogicWholeCandidateStaging.create(control: control) }
        catch { throw pexFailure(error) }
        let result: PreparedSPICESimulation
        do {
            let fragmentURL = try await staging.writeFragment(fragment.value, control: control)
            let rawLease = try control.reserve(try PhysicalLogicWholeCandidateControl.sum(
                UInt64(MemoryLayout<PEXRawOutput>.stride),
                PhysicalLogicWholeCandidateControl.sum(UInt64(MemoryLayout<[URL]>.stride), UInt64(MemoryLayout<URL>.stride))))
            defer { withExtendedLifetime(rawLease) {} }
            let raw = PEXRawOutput(format: .spice, fileURLs: [fragmentURL])
            let parseContext = PEXParseContext(cornerID: request.pexCorner, runID: .init(),
                topCell: nil, technology: nil, options: .default)
            let cold: (value: ParasiticIR, retention: PEXParserRetention)
            let composed: (value: String, retention: PEXParserRetention)
            do {
                cold = try MagicSPICEParasiticParser().parse(raw, context: parseContext, control: adapter)
                try PhysicalLogicWholeCandidatePassiveMultiset.requireEqual(lowered.value, cold.value, control: control)
                composed = try PEXSPICEBackannotationComposer(options: .init(topCell: nil,
                    subcircuitName: "whole_pex", instanceName: "XPEX_whole", requirePortMatches: true))
                    .compose(sourceNetlist: original, ir: lowered.value, control: adapter)
            } catch { throw pexFailure(error) }
            defer { withExtendedLifetime((cold.retention, composed.retention)) {} }
            let count = composed.value.utf8.count
            guard UInt64(count) <= control.limits.maximumComposedBytes else {
                throw PhysicalLogicWholeCandidateFlowFailure.parasitics("Composed source exceeds output ceiling")
            }
            let generatedLease = try control.slots(UInt8.self, count: count)
            defer { withExtendedLifetime(generatedLease) {} }
            let generated = try copy(composed.value.utf8, count: count, control: control)
            // Binding digest storage becomes caller input to Core's source admission,
            // so its lease is retained by the replacement provider, not this stack.
            let bindingLease = try control.reserve(try PhysicalLogicWholeCandidateControl.sum(
                UInt64(MemoryLayout<SPICEExactSourceBinding>.stride), 64), kind: .liveOwnedBytes)
            let hash = try digest(generated, pageByteCount: request.source.limits.maximumPageByteCount, control: control)
            let reference = try ArtifactReference(digest: hash.digest, byteCount: UInt64(count),
                descriptor: request.source.root.binding.reference.descriptor)
            let binding = SPICEExactSourceBinding(key: request.source.root.binding.key, reference: reference)
            let root = try SPICECheckedSource.admit(binding: binding, bytes: generated.span,
                resources: control, maximumPageByteCount: request.source.limits.maximumPageByteCount)
            let sourceRequest = try PhysicalLogicWholeCandidateSources.replacingRoot(root, in: request.source,
                retaining: bindingLease, control: control)
            do { result = try await SPICESimulationPreparer().prepare(sourceRequest, resources: control) }
            catch { throw sourceFailure(error) }
            try control.check()
            try PhysicalLogicWholeCandidatePassiveValidation.validate(source: result, cold: cold.value, control: control)
        } catch {
            let primary = pexFailure(error)
            do { try await staging.remove() }
            catch { throw PhysicalLogicWholeCandidateFlowFailure.stagingCleanup(
                PhysicalLogicWholeCandidateStagingCleanupFailure(primary: primary, secondary: error, owner: staging)) }
            throw primary
        }
        do { try await staging.remove() }
        catch { throw PhysicalLogicWholeCandidateFlowFailure.stagingCleanup(
            PhysicalLogicWholeCandidateStagingCleanupFailure(primary: nil, secondary: error, owner: staging)) }
        try control.check()
        return result
    }

    private struct PEXControl: PEXParserResourceControlling {
        let owner: PhysicalLogicWholeCandidateControl
        func checkpoint(workUnits: UInt64) throws { try owner.check(workUnits) }
        func reserveStorage(kind: PEXParserStorageKind, byteCount: UInt64) throws -> any Sendable {
            try owner.reserveStorage(kind: kind == .temporary ? .temporaryBytes : .liveOwnedBytes, byteCount: byteCount)
        }
    }
    private static func pexFailure(_ error: any Error) -> PhysicalLogicWholeCandidateFlowFailure {
        if let failure = error as? PhysicalLogicWholeCandidateFlowFailure { return failure }
        return .lower(phase: .parasitics, cause: error)
    }
    private static func sourceFailure(_ error: any Error) -> PhysicalLogicWholeCandidateFlowFailure {
        if let failure = error as? PhysicalLogicWholeCandidateFlowFailure { return failure }
        if case SPICESimulationPreparationError.resource(let cause) = error,
           let failure = cause as? PhysicalLogicWholeCandidateFlowFailure { return failure }
        return .lower(phase: .source, cause: error)
    }
    private static func textBytes(_ count: Int) throws -> UInt64 {
        try PhysicalLogicWholeCandidateControl.sum(UInt64(MemoryLayout<String>.stride), UInt64(count))
    }
    private static func copy(_ data: Data, control: PhysicalLogicWholeCandidateControl) throws -> [UInt8] {
        try copy(data, count: data.count, control: control)
    }
    private static func copy<C: Collection>(_ bytes: C, count: Int,
        control: PhysicalLogicWholeCandidateControl) throws -> [UInt8] where C.Element == UInt8 {
        var result: [UInt8] = []; result.reserveCapacity(count)
        var offset = 0
        for byte in bytes {
            if offset.isMultiple(of: 256) { try control.check() }
            result.append(byte); offset += 1
        }
        try control.check(UInt64(count))
        guard result.count == count else { throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Changed byte projection") }
        return result
    }
    private static func digest(_ bytes: [UInt8], pageByteCount: UInt64,
        control: PhysicalLogicWholeCandidateControl) throws -> ContentDigestResult {
        guard pageByteCount > 0, let page = Int(exactly: pageByteCount) else {
            throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Invalid source hash page")
        }
        let capacity = min(page, bytes.count)
        let lease = try control.slots(UInt8.self, count: capacity)
        defer { withExtendedLifetime(lease) {} }
        var chunk: [UInt8] = []; chunk.reserveCapacity(capacity)
        var resourceFailure: (any Error)?
        let value: ContentDigestResult
        do {
            value = try SHA256ContentDigester().digest(using: .sha256,
                limits: .init(maximumChunkByteCount: pageByteCount, maximumTotalByteCount: max(1, UInt64(bytes.count)),
                    maximumUpdateCount: bytes.isEmpty ? 1 : (UInt64(bytes.count) - 1) / pageByteCount + 1)) {
                        (session: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
                var offset = 0
                while offset < bytes.count {
                    let end = offset + min(page, bytes.count - offset)
                    do {
                        try control.check(); try control.chargeHashedBytes(UInt64(end - offset))
                        chunk.removeAll(keepingCapacity: true)
                        for index in offset..<end {
                            if (index - offset).isMultiple(of: 256) { try control.check() }
                            chunk.append(bytes[index])
                        }
                    } catch {
                        resourceFailure = error
                        throw .backendUpdateFailed(reason: "Whole-candidate source accounting refused")
                    }
                    try session.update(chunk)
                    offset = end
                }
            }
        } catch {
            if let resourceFailure { throw resourceFailure }
            throw error
        }
        try control.check()
        return value
    }
}
