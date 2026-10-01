import LEF

struct PhysicalDesignMasterGeometry: Sendable {
    private let masters: [String: [LEFMacroDef]]

    init(_ definitions: [LEFMacroDef]) {
        masters = Dictionary(grouping: definitions, by: \.name)
    }

    var isEmpty: Bool { masters.isEmpty }

    func dimensions(of name: String, units: Int) throws -> (width: Int64, height: Int64) {
        guard let matches = masters[name], matches.count == 1, let master = matches.first else {
            throw PhysicalDesignTechnologyError.invalid("Master \(name) requires one exact LEF definition.")
        }
        return (
            try PhysicalDesignProcessInputs.dbu(master.width, units: units, field: "\(name).SIZE width", positive: true),
            try PhysicalDesignProcessInputs.dbu(master.height, units: units, field: "\(name).SIZE height", positive: true)
        )
    }
}
