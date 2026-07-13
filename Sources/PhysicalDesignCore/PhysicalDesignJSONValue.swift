import Foundation

/// Domain-local JSON value used by design-diff artifacts.
public enum PhysicalDesignJSONValue: Sendable, Hashable, Codable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([PhysicalDesignJSONValue])
    case object([String: PhysicalDesignJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        do {
            self = .boolean(try container.decode(Bool.self))
            return
        } catch {}
        do {
            self = .number(try container.decode(Double.self))
            return
        } catch {}
        do {
            self = .string(try container.decode(String.self))
            return
        } catch {}
        do {
            self = .array(try container.decode([PhysicalDesignJSONValue].self))
            return
        } catch {}
        self = .object(try container.decode([String: PhysicalDesignJSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
