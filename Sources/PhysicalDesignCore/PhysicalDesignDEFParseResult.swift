import Foundation

public struct PhysicalDesignDEFParseResult: Sendable, Hashable, Codable {
    public var snapshot: PhysicalDesignSnapshot?
    public var diagnostics: [PhysicalDesignDEFDiagnostic]

    public init(snapshot: PhysicalDesignSnapshot?, diagnostics: [PhysicalDesignDEFDiagnostic]) {
        self.snapshot = snapshot
        self.diagnostics = diagnostics
    }

    public var isValid: Bool {
        snapshot != nil && !diagnostics.contains { $0.severity == .error }
    }
}
