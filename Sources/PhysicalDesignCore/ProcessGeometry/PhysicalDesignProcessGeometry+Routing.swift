import MaskGeometry
import LayoutIR

extension PhysicalDesignProcessGeometry {
    func routingWidthAndSpacing(layer: Int, units: Int, width: Int64) throws -> (width: Int64, spacing: Int64) {
        guard let native = Int16(exactly: layer), let source = sourceLayers[native], source.type == .routing,
              let declared = source.width, source.direction != nil else {
            throw PhysicalDesignRoutingSourceError(code: "routing_layer_semantics_missing", message: "Layer \(layer) requires exact source WIDTH and DIRECTION.")
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): The native signal router implements scalar default-width rules. Parallel-run-length tables and area-dependent rules must remain explicitly unsupported until their actual geometric semantics are implemented.
        guard source.spacingTable == nil, source.area == nil else {
            throw PhysicalDesignRoutingSourceError(code: "routing_layer_rules_unsupported", message: "Advanced routing layer rules are outside the scalar native profile.")
        }
        let actual = try PhysicalDesignProcessInputs.dbu(declared, units: units, field: "\(source.name).WIDTH")
        guard width == actual, actual > 0, actual.isMultiple(of: 2) else {
            throw PhysicalDesignRoutingSourceError(code: "routing_width_unsupported", message: "Conductor width must match the even exact declared default WIDTH of \(source.name).")
        }
        if let minimum = source.minwidth, width < (try PhysicalDesignProcessInputs.dbu(minimum, units: units, field: "MINWIDTH")) {
            throw PhysicalDesignRoutingSourceError(code: "routing_width_unsupported", message: "Declared WIDTH violates MINWIDTH.")
        }
        if let maximum = source.maxwidth, width > (try PhysicalDesignProcessInputs.dbu(maximum, units: units, field: "MAXWIDTH")) {
            throw PhysicalDesignRoutingSourceError(code: "routing_width_unsupported", message: "Declared WIDTH violates MAXWIDTH.")
        }
        let spacing = try source.spacing.map { try PhysicalDesignProcessInputs.dbu($0, units: units, field: "\(source.name).SPACING") } ?? 0
        guard spacing >= 0 else { throw PhysicalDesignTechnologyError.invalid("Routing SPACING cannot be negative.") }
        return (actual, spacing)
    }

    func validateRoutingCuts(_ contacts: [PhysicalDesignSnapshot.Via], sourceCuts: [IRBoundary] = []) throws {
        var cuts = Dictionary(grouping: sourceCuts, by: \.layer)
        for via in contacts {
            guard let master = via.master, let declared = vias[master] else { throw PhysicalDesignTechnologyError.invalid("Routing contact requires an exact fixed source.") }
            cuts[declared.cutLayer, default: []].append(contentsOf: try viaShapes(master: master, x: via.x, y: via.y).filter { $0.layer == declared.cutLayer })
        }
        for (layer, shapes) in cuts { try Self.validateCutSpacing(shapes, minimum: cutSpacings[layer]) }
    }

    func routingCutsFit(_ candidate: PhysicalDesignSnapshot.Via, against existing: [PhysicalDesignSnapshot.Via], sourceCuts: [IRBoundary] = []) throws -> Bool {
        do { try validateRoutingCuts(existing + [candidate], sourceCuts: sourceCuts); return true }
        catch PhysicalDesignTechnologyError.invalid { return false }
    }
}
