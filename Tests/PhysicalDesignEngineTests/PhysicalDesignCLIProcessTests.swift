import Foundation
import Testing

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

    private func executableURL(named name: String) throws -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let productsDirectory = environment["BUILT_PRODUCTS_DIR"] {
            candidates.append(URL(fileURLWithPath: productsDirectory).appending(path: name))
        }
        var processAncestor = URL(fileURLWithPath: CommandLine.arguments[0])
        for _ in 0..<8 {
            processAncestor.deleteLastPathComponent()
            candidates.append(processAncestor.appending(path: name))
        }
        var ancestor = Bundle.main.bundleURL
        for _ in 0..<6 {
            ancestor.deleteLastPathComponent()
            candidates.append(ancestor.appending(path: name))
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            var bundleAncestor = bundle.bundleURL
            for _ in 0..<6 {
                bundleAncestor.deleteLastPathComponent()
                candidates.append(bundleAncestor.appending(path: name))
            }
        }
        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false))
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }
}
