import Foundation
import Darwin
import CoreSpiceIO

/// Serializes the lifetime of one exclusive, identity-bound host staging directory.
internal actor PhysicalLogicWholeCandidateStaging {
    typealias Failure = PhysicalLogicWholeCandidateStagingCleanupFailure.DirectoryFailure
    nonisolated let directory: URL
    private let fragmentURL: URL
    private let control: PhysicalLogicWholeCandidateControl
    private let metadataStorage: SPICESourceStorageReservation
    private var state = State()
    private struct Identity: Equatable, Sendable { let device: dev_t; let inode: ino_t }
    private struct State {
        var identity: Identity?
        var created = false
        var removed = false
        var written = false
        var fileStorage: SPICESourceStorageReservation?
    }

    private init(directory: URL, fragmentURL: URL, control: PhysicalLogicWholeCandidateControl,
                 storage: SPICESourceStorageReservation) {
        self.directory = directory; self.fragmentURL = fragmentURL
        self.control = control; metadataStorage = storage
    }

    static func create(control: PhysicalLogicWholeCandidateControl) async throws -> PhysicalLogicWholeCandidateStaging {
        try control.check()
        let base = FileManager.default.temporaryDirectory
        let baseBytes = try pathByteCount(base, control: control)
        let prefix = "physical-whole-candidate-"
        let directoryBytes = try PhysicalLogicWholeCandidateControl.sum(UInt64(baseBytes),
            PhysicalLogicWholeCandidateControl.sum(1, UInt64(prefix.utf8.count + 36)))
        let fragmentBytes = try PhysicalLogicWholeCandidateControl.sum(directoryBytes, UInt64(1 + "fragment.cir".utf8.count))
        var metadata: UInt64 = 0
        func field<T>(_ type: T.Type) throws {
            let alignment = UInt64(MemoryLayout<T>.alignment), remainder = metadata % UInt64(MemoryLayout<T>.alignment)
            if remainder != 0 { metadata = try PhysicalLogicWholeCandidateControl.sum(metadata, alignment - remainder) }
            metadata = try PhysicalLogicWholeCandidateControl.sum(metadata, UInt64(MemoryLayout<T>.stride))
        }
        try field(URL.self); try field(URL.self); try field(PhysicalLogicWholeCandidateControl.self)
        try field(SPICESourceStorageReservation.self); try field(State.self)
        // Pre-admit the failure wrapper before filesystem effects: cancellation
        // during cleanup cannot prevent retention of its primary/secondary owner.
        try field(PhysicalLogicWholeCandidateStagingCleanupFailure.self)
        try field(UUID.self); try field(String.self); try field(String.self)
        metadata = try PhysicalLogicWholeCandidateControl.sum(metadata, UInt64(prefix.utf8.count + 36 + 36))
        // A file URL percent-encodes each filesystem UTF-8 byte into at most
        // three ASCII bytes, plus the seven-byte file:// scheme. This is an
        // encoding-derived envelope, not a guessed source-payload multiplier.
        let urlBytes = try PhysicalLogicWholeCandidateControl.sum(
            PhysicalLogicWholeCandidateControl.product(directoryBytes, 3),
            PhysicalLogicWholeCandidateControl.product(fragmentBytes, 3))
        metadata = try PhysicalLogicWholeCandidateControl.sum(metadata,
            PhysicalLogicWholeCandidateControl.sum(14, urlBytes))
        let storage = try control.reserve(metadata, kind: .liveOwnedBytes)
        try control.check()
        let name = prefix + UUID().uuidString
        let directory = base.appendingPathComponent(name, isDirectory: true)
        let fragment = directory.appendingPathComponent("fragment.cir", isDirectory: false)
        let owner = PhysicalLogicWholeCandidateStaging(directory: directory, fragmentURL: fragment, control: control, storage: storage)
        try await owner.initialize()
        return owner
    }

    private func initialize() throws {
        try control.check()
        // Foundation owns this NUL-terminated pointer for this closure only.
        // mkdir reads it synchronously; no pointer escapes and no buffer is
        // manually allocated, aliased, rebound or deallocated by this component.
        try directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw Failure.unrepresentablePath }
            guard Darwin.mkdir(path, 0o700) == 0 else {
                throw Failure.systemCall(operation: .create, code: errno)
            }
        }
        state.created = true
        do { state.identity = try Self.identity(directory) }
        catch {
            throw PhysicalLogicWholeCandidateFlowFailure.stagingCleanup(
                PhysicalLogicWholeCandidateStagingCleanupFailure(primary: nil, secondary: error, owner: self))
        }
    }

    func writeFragment(_ text: String, control supplied: PhysicalLogicWholeCandidateControl) throws -> URL {
        guard supplied === control else { throw Failure.unverifiedIdentity }
        try control.check()
        guard !state.written, !state.removed else { throw Failure.duplicateWrite }
        try requireIdentity()
        let count = text.utf8.count
        let bytes = try PhysicalLogicWholeCandidateControl.sum(UInt64(MemoryLayout<Data>.stride), UInt64(count))
        let dataLease = try control.reserve(bytes)
        defer { withExtendedLifetime(dataLease) {} }
        state.fileStorage = try control.reserve(UInt64(count), kind: .liveOwnedBytes)
        try control.check()
        var data = Data(); data.reserveCapacity(count)
        var offset = 0
        for byte in text.utf8 {
            if offset.isMultiple(of: 256) { try control.check() }
            data.append(byte); offset += 1
        }
        try control.check(UInt64(count))
        // This directory is private to this operation and this actor permits
        // only one fragment write. Atomic Foundation workspace is opaque; its
        // materialized Data and complete file payload have separate admissions.
        try data.write(to: fragmentURL, options: .atomic)
        state.written = true
        try control.check()
        return fragmentURL
    }

    /// Deliberately checks neither Task nor invocation cancellation. Every caller
    /// awaits completion, including error paths; actor isolation serializes retry.
    func remove() throws {
        if state.removed { return }
        guard state.created else { throw Failure.unverifiedIdentity }
        try requireIdentity()
        try FileManager.default.removeItem(at: directory)
        state.removed = true
        state.fileStorage = nil
    }

    private func requireIdentity() throws {
        guard let expected = state.identity else { throw Failure.unverifiedIdentity }
        guard try Self.identity(directory) == expected else { throw Failure.replacement }
    }
    private static func identity(_ url: URL) throws -> Identity {
        // The initialized stat value lives on this stack. lstat borrows the URL's
        // path pointer only in the closure, follows no final symlink and returns
        // numeric identity. No foreign pointer or mutable storage is retained.
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw Failure.unrepresentablePath }
            var value = stat()
            guard Darwin.lstat(path, &value) == 0 else {
                let code = errno
                if code == ENOENT { throw Failure.missing }
                throw Failure.systemCall(operation: .inspect, code: code)
            }
            guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw Failure.replacement }
            return Identity(device: value.st_dev, inode: value.st_ino)
        }
    }
    private static func pathByteCount(_ url: URL, control: PhysicalLogicWholeCandidateControl) throws -> Int {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw Failure.unrepresentablePath }
            var count = 0
            while path[count] != 0 {
                if count.isMultiple(of: 256) { try control.check() }
                let next = count.addingReportingOverflow(1)
                guard !next.overflow else { throw PhysicalLogicWholeCandidateFlowFailure.invalidInput("Path length overflow") }
                count = next.partialValue
            }
            return count
        }
    }
}
