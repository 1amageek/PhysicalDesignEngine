import Foundation
import PhysicalDesignCore
import PhysicalDesignEngine

public struct PhysicalDesignCLICommand: Sendable {
    public init() {}

    public func invoke(
        arguments: [String],
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async -> PhysicalDesignCLIInvocationResult {
        do {
            let options = try parse(arguments: arguments, currentDirectory: currentDirectory)
            if options.help {
                return PhysicalDesignCLIInvocationResult(output: Self.helpText, exitCode: 0)
            }
            let requestData: Data
            if let requestPath = options.requestPath {
                requestData = try Data(contentsOf: requestPath)
            } else {
                requestData = FileHandle.standardInput.readDataToEndOfFile()
            }
            let codec = PhysicalDesignJSONCodec()
            let request = try codec.decode(PhysicalDesignRequest.self, from: requestData)
            let store = FileSystemPhysicalDesignArtifactStore(projectRoot: options.projectRoot)
            let engine = PhysicalDesignEngine(artifactStore: store)
            let result = try await engine.execute(request)
            return PhysicalDesignCLIInvocationResult(
                output: String(decoding: try codec.encode(result), as: UTF8.self),
                exitCode: result.status == .completed ? 0 : 1
            )
        } catch let error as PhysicalDesignCLIError {
            return PhysicalDesignCLIInvocationResult(
                output: encodeError(error.code, message: error.localizedDescription, actions: error.actions),
                exitCode: 2
            )
        } catch {
            return PhysicalDesignCLIInvocationResult(
                output: encodeError("cli_execution_failed", message: error.localizedDescription, actions: ["inspect_request_and_project_root"]),
                exitCode: 1
            )
        }
    }

    public static var helpText: String {
        """
        physical-design [--request <path>] [--project-root <path>]

        Reads a PhysicalDesignRequest JSON document from --request or stdin and emits one JSON result envelope.
        Execution intent selects the native geometry or OpenROAD process backend.
        Immutable artifacts are written under runs/<run-id>/physical-design/.
        """
    }

    private func parse(arguments: [String], currentDirectory: URL) throws -> Options {
        var requestPath: URL?
        var projectRoot = currentDirectory
        var help = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                help = true
            case "--request":
                index += 1
                guard index < arguments.count else { throw PhysicalDesignCLIError.missingValue("--request") }
                requestPath = URL(fileURLWithPath: arguments[index], relativeTo: currentDirectory).standardizedFileURL
            case "--project-root":
                index += 1
                guard index < arguments.count else { throw PhysicalDesignCLIError.missingValue("--project-root") }
                projectRoot = URL(fileURLWithPath: arguments[index], relativeTo: currentDirectory).standardizedFileURL
            default:
                throw PhysicalDesignCLIError.unknownOption(argument)
            }
            index += 1
        }
        return Options(requestPath: requestPath, projectRoot: projectRoot, help: help)
    }

    private func encodeError(_ code: String, message: String, actions: [String]) -> String {
        let output = PhysicalDesignCLIErrorOutput(code: code, message: message, suggestedActions: actions)
        do {
            let codec = PhysicalDesignJSONCodec()
            return String(decoding: try codec.encode(output), as: UTF8.self)
        } catch {
            return "{\"status\":\"failed\",\"code\":\"cli_encoding_failed\"}"
        }
    }

    private struct Options: Sendable {
        var requestPath: URL?
        var projectRoot: URL
        var help: Bool
    }
}
