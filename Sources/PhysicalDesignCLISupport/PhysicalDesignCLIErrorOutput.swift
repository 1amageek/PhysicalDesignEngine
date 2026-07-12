import Foundation

public struct PhysicalDesignCLIErrorOutput: Sendable, Hashable, Codable {
    public var status: String
    public var code: String
    public var message: String
    public var suggestedActions: [String]

    public init(code: String, message: String, suggestedActions: [String] = []) {
        self.status = "failed"
        self.code = code
        self.message = message
        self.suggestedActions = suggestedActions
    }
}
