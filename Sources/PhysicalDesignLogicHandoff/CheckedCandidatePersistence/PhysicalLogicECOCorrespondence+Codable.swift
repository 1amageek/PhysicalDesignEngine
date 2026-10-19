import CircuiteFoundation

extension PhysicalLogicECOCorrespondence: Codable {
    private struct Entry<Value: Codable>: Codable {
        let id: UInt64
        let value: Value
    }
    private enum Keys: String, CodingKey { case instances, nets, ports, states }

    public func encode(to encoder: any Encoder) throws {
        func entries<Value: Codable>(_ values: [DesignEntityID: Value]) -> [Entry<Value>] {
            values.keys.sorted().map { .init(id: $0.rawValue, value: values[$0]!) }
        }
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(entries(instanceIDs), forKey: .instances)
        try container.encode(entries(netIDs), forKey: .nets)
        try container.encode(entries(portPinIDs), forKey: .ports)
        try container.encode(entries(stateInstanceIDs), forKey: .states)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        func table<Value: Codable>(_ records: [Entry<Value>]) throws -> [DesignEntityID: Value] {
            var result: [DesignEntityID: Value] = [:]
            for record in records {
                let id = try DesignEntityID(rawValue: record.id)
                guard result.updateValue(record.value, forKey: id) == nil else {
                    throw PhysicalLogicCandidateArtifactError.invalidBinding("Duplicate saved canonical correspondence")
                }
            }
            return result
        }
        self.init(instanceIDs: try table(container.decode([Entry<String>].self, forKey: .instances)),
            netIDs: try table(container.decode([Entry<String>].self, forKey: .nets)),
            portPinIDs: try table(container.decode([Entry<[String]>].self, forKey: .ports)),
            stateInstanceIDs: try table(container.decode([Entry<String>].self, forKey: .states)))
    }
}
