import Foundation

public struct PhysicalDesignDEFParseError: Error, Sendable {
    public let diagnostics: [PhysicalDesignDEFDiagnostic]

    public init(diagnostics: [PhysicalDesignDEFDiagnostic]) {
        self.diagnostics = diagnostics
    }
}
