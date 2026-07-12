import Foundation
import PhysicalDesignCore
import PhysicalDesignEngine

public struct PhysicalDesignCLICommand: Sendable {
    public init() {}

    public func run(
        arguments: [String],
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async -> String {
        do {
            let options = try parse(arguments: arguments, currentDirectory: currentDirectory)
            if options.help {
                return Self.helpText
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
            return String(decoding: try codec.encode(result), as: UTF8.self)
        } catch let error as PhysicalDesignCLIError {
            return encodeError(error.code, message: error.localizedDescription, actions: error.actions)
        } catch {
            return encodeError("cli_execution_failed", message: error.localizedDescription, actions: ["inspect_request_and_project_root"])
        }
    }

    public static var helpText: String {
        """
        physical-design [--request <path>] [--project-root <path>]

        Reads a PhysicalDesignRequest JSON document from --request or stdin and emits one JSON result envelope.
        Native execution writes immutable artifacts under runs/<run-id>/physical-design/.
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
