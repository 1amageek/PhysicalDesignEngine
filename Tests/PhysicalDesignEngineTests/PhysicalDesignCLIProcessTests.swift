import Foundation
import Testing
import PhysicalDesignCore

@Suite("Physical design CLI process")
struct PhysicalDesignCLIProcessTests {
    @Test("invalid invocation exits nonzero")
    func invalidInvocationExitsNonzero() throws {
        let process = Process()
        process.executableURL = try executableURL(named: "physical-design")
        process.arguments = ["--unknown"]
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()

        #expect(process.terminationStatus != 0)
        #expect(String(decoding: output, as: UTF8.self).contains("unknown_option"))
    }

    @Test("retained requests execute through the CLI", arguments: [
        "positive-floorplan-request", "positive-technology-floorplan-request", "negative-missing-snapshot-request", "negative-native-production-request"
    ])
    func retainedRequestFixtures(name: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "physical-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("CLI fixture cleanup failed: \(error)") }
        }
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        try FileManager.default.copyItem(at: fixtures, to: root.appending(path: "Fixtures"))
        let requestURL = root.appending(path: "Fixtures/\(name).json")
        let codec = PhysicalDesignJSONCodec()
        let request = try codec.decode(PhysicalDesignRequest.self, from: Data(contentsOf: requestURL))
        let store = FileSystemPhysicalDesignArtifactStore(projectRoot: root)
        for binding in request.inputBindings { _ = try await store.read(binding) }

        let process = Process()
        process.executableURL = try executableURL(named: "physical-design")
        process.arguments = ["--request", requestURL.path, "--project-root", root.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = try codec.decode(PhysicalDesignResult.self, from: output)
        if name.hasPrefix("positive-") {
            #expect(process.terminationStatus == 0)
            #expect(result.status == .completed)
            #expect(result.artifactBindings.count == 4)
            for binding in result.artifactBindings { _ = try await store.read(binding) }
            if name == "positive-technology-floorplan-request" {
                let binding = try #require(result.artifactBindings.first { $0.path.hasSuffix("revision.json") })
                let snapshot = try codec.decode(PhysicalDesignSnapshot.self, from: await store.read(binding))
                let tracks = try #require(snapshot.implementationState?.tracks)
                #expect(tracks.first { $0.layer == 2 }?.spacing == 200)
                #expect(tracks.first { $0.layer == 3 }?.spacing == 400)
                #expect(tracks.allSatisfy { $0.origin == 10_100 && $0.count == 400 })
                #expect(snapshot.metadata["technologyLEFContentIDs"] != nil)
            }
        } else {
            #expect(process.terminationStatus != 0)
            #expect(result.status == .blocked)
            #expect(result.artifacts.isEmpty)
            let code = name == "negative-missing-snapshot-request"
                ? "physical_snapshot_missing" : "native_production_implementation_unsupported"
            #expect(result.diagnostics.contains { $0.code.rawValue == code })
        }
        #expect(result.payload.claims.production == .blocked)
    }

    private func executableURL(named name: String) throws -> URL {
        var directory = Bundle.module.bundleURL
        // SwiftPM resources are adjacent to products or embedded in .xctest/Contents/Resources.
        for _ in 0..<4 {
            directory.deleteLastPathComponent()
            let executable = directory.appending(path: name)
            if FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) {
                return executable
            }
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: directory.appending(path: name).path])
    }
}
