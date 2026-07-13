import Foundation

public struct PhysicalDesignDesignDiffChange: Sendable, Hashable, Codable {
    public var changeID: String
    public var domain: PhysicalDesignDesignDiff.Domain
    public var operation: PhysicalDesignDesignDiff.Operation
    public var path: String
    public var before: PhysicalDesignJSONValue?
    public var after: PhysicalDesignJSONValue?
    public var summary: String

    public init(changeID: String, domain: PhysicalDesignDesignDiff.Domain, operation: PhysicalDesignDesignDiff.Operation, path: String, before: PhysicalDesignJSONValue?, after: PhysicalDesignJSONValue?, summary: String) {
        self.changeID = changeID
        self.domain = domain
        self.operation = operation
        self.path = path
        self.before = before
        self.after = after
        self.summary = summary
    }
}
