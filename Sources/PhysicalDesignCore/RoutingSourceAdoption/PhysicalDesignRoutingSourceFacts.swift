import LEF

/// Typed subset authority for source facts; no serialized-key or lexical inference.
enum PhysicalDesignRoutingSourceFacts {
    static func preserved(_ old: LEFDocument, in new: LEFDocument) throws -> Bool {
        guard old.version == new.version, old.dbuPerMicron == new.dbuPerMicron,
              old.hasDatabaseUnitsDeclaration == new.hasDatabaseUnitsDeclaration,
              old.unitDeclarations == new.unitDeclarations,
              same(old.manufacturingGrid, new.manufacturingGrid),
              same(old.obstructionSpacingUsesMinimumWidth, new.obstructionSpacingUsesMinimumWidth),
              same(old.busbitChars, new.busbitChars), same(old.dividerChar, new.dividerChar),
              old.properties.isEmpty || old.properties == new.properties,
              old.propertyDefinitions.isEmpty || old.propertyDefinitions == new.propertyDefinitions,
              old.viaGenerationRules.isEmpty || old.viaGenerationRules == new.viaGenerationRules else { return false }
        for layer in old.layers {
            try Task.checkCancellation()
            let matches = new.layers.filter { $0.name == layer.name }
            guard matches.count == 1, let candidate = matches.first, preserved(layer, in: candidate) else { return false }
        }
        for site in old.sites { try Task.checkCancellation(); guard new.sites.filter({ $0.name == site.name }) == [site] else { return false } }
        for via in old.vias { try Task.checkCancellation(); guard new.vias.filter({ $0.name == via.name }) == [via] else { return false } }
        for macro in old.macros { try Task.checkCancellation(); guard new.macros.filter({ $0.name == macro.name }) == [macro] else { return false } }
        return true
    }

    private static func same<T: Equatable>(_ old: T?, _ new: T?) -> Bool { old == nil || old == new }

    private static func preserved(_ old: LEFLayerDef, in new: LEFLayerDef) -> Bool {
        // Clear only facts the old source did not declare, then compare the entire typed value.
        var candidate = new
        if old.direction == nil { candidate.direction = nil }
        if old.pitch == nil { candidate.pitch = nil }
        if old.offset == nil { candidate.offset = nil }
        if old.width == nil { candidate.width = nil }
        if old.spacing == nil { candidate.spacing = nil }
        if old.resistance == nil { candidate.resistance = nil }
        if old.cutResistanceOhms == nil { candidate.cutResistanceOhms = nil }
        if old.capacitance == nil { candidate.capacitance = nil }
        if old.edgeCapacitance == nil { candidate.edgeCapacitance = nil }
        if old.thickness == nil { candidate.thickness = nil }
        if old.minwidth == nil { candidate.minwidth = nil }
        if old.maxwidth == nil { candidate.maxwidth = nil }
        if old.area == nil { candidate.area = nil }
        if old.spacingTable == nil { candidate.spacingTable = nil }
        if old.minimumDensity == nil { candidate.minimumDensity = nil }
        if old.maximumDensity == nil { candidate.maximumDensity = nil }
        if old.densityCheckWindow == nil { candidate.densityCheckWindow = nil }
        if old.densityCheckStep == nil { candidate.densityCheckStep = nil }
        if old.subtype == nil { candidate.subtype = nil }
        if old.minimumEnclosedAreas.isEmpty { candidate.minimumEnclosedAreas = [] }
        if old.enclosures.isEmpty { candidate.enclosures = [] }
        if old.properties.isEmpty { candidate.properties = [] }
        if old.currentDensityLimits.isEmpty { candidate.currentDensityLimits = [] }
        if old.antennaStatements.isEmpty { candidate.antennaStatements = [] }
        return old == candidate
    }

    static func admitEntries(_ inputs: PhysicalDesignProcessInputs, remaining: inout Int) throws {
        func charge(_ count: Int, _ remaining: inout Int) throws {
            try Task.checkCancellation()
            guard count >= 0, count <= remaining else {
                throw PhysicalDesignRoutingSourceAdoptionError(.limitsExceeded, "Parsed source entries exceed the caller allowance.")
            }
            remaining -= count
        }
        func admitPort(_ port: LEFPort, _ remaining: inout Int) throws {
            try charge(1, &remaining)
            guard port.rects.count <= remaining / 4 else {
                throw PhysicalDesignRoutingSourceAdoptionError(.limitsExceeded, "Source rectangle entries exceed the caller allowance.")
            }
            try charge(port.rects.count * 4, &remaining)
            try charge(port.vias.count, &remaining)
            try charge(port.paths.count, &remaining)
            for polygon in port.polygons { try charge(1, &remaining); try charge(polygon.count, &remaining) }
            for path in port.paths { try charge(path.points.count, &remaining) }
        }
        try charge(inputs.manifest.layers.count, &remaining)
        try charge(inputs.manifest.assets.count, &remaining)
        for layer in inputs.manifest.layers { try charge(layer.aliases.count, &remaining) }
        for mapping in inputs.manifest.crossViewMappings {
            try charge(1, &remaining); try charge(mapping.layerIDs.count, &remaining)
            try charge(mapping.physicalNames.count, &remaining); try charge(mapping.logicalNames.count, &remaining)
            try charge(mapping.deviceIDs.count, &remaining); try charge(mapping.cornerIDs.count, &remaining)
        }
        for views in [inputs.technologyViews, inputs.cellViews] {
            for document in views.values {
                try charge(document.layers.count, &remaining)
                try charge(document.sites.count, &remaining)
                try charge(document.vias.count, &remaining)
                try charge(document.viaGenerationRules.count, &remaining)
                for rule in document.viaGenerationRules {
                    try charge(rule.routingLayers.count, &remaining); try charge(5, &remaining)
                }
                try charge(document.macros.count, &remaining)
                try charge(document.propertyDefinitions.count, &remaining)
                try charge(document.properties.count, &remaining)
                for layer in document.layers {
                    try charge(layer.antennaStatements.count, &remaining)
                    try charge(layer.enclosures.count, &remaining)
                    try charge(layer.properties.count, &remaining)
                    try charge(layer.currentDensityLimits.count, &remaining)
                    try charge(layer.minimumEnclosedAreas.count, &remaining)
                    if let table = layer.spacingTable {
                        try charge(table.parallelRunLengths.count, &remaining)
                        for row in table.widthEntries {
                            try charge(1, &remaining); try charge(row.spacings.count, &remaining)
                        }
                    }
                }
                for via in document.vias {
                    try charge(via.layers.count, &remaining)
                    for layer in via.layers {
                        guard layer.rects.count <= remaining / 4 else {
                            throw PhysicalDesignRoutingSourceAdoptionError(.limitsExceeded, "VIA rectangle entries exceed the caller allowance.")
                        }
                        try charge(layer.rects.count * 4, &remaining)
                        for polygon in layer.polygons { try charge(1, &remaining); try charge(polygon.count, &remaining) }
                    }
                }
                for macro in document.macros {
                    try charge(macro.pins.count, &remaining)
                    try charge(macro.properties.count, &remaining)
                    for port in macro.obs { try admitPort(port, &remaining) }
                    for pin in macro.pins {
                        try charge(pin.properties.count, &remaining)
                        for port in pin.ports { try admitPort(port, &remaining) }
                    }
                }
            }
        }
    }
}
