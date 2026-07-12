import Foundation
import XcircuitePackage

public struct PhysicalDesignDEFDiagnostic: Sendable, Hashable, Codable {
    public var severity: XcircuiteEngineDiagnosticSeverity
    public var code: String
    public var message: String
    public var line: Int
    public var section: String
    public var entity: String?
    public var suggestedActions: [String]

    public init(
        severity: XcircuiteEngineDiagnosticSeverity,
        code: String,
        message: String,
        line: Int,
        section: String,
        entity: String? = nil,
        suggestedActions: [String] = []
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.line = line
        self.section = section
        self.entity = entity
        self.suggestedActions = suggestedActions
    }
}
