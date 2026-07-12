import Foundation
import XcircuitePackage

public struct PhysicalDesignJSONCodec: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    public func jsonValue<T: Encodable>(_ value: T) throws -> XcircuiteJSONValue {
        try decode(XcircuiteJSONValue.self, from: encode(value))
    }
}
