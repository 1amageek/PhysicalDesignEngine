import MaskGeometry
import LayoutIR

extension PhysicalDesignProcessGeometry {
    func routingWidthAndSpacing(layer: Int, units: Int, width: Int64?, explicitSpecialWidth: Bool = false, areaHandledSeparately: Bool = false) throws -> (width: Int64, spacing: Int64) {
        guard let native = Int16(exactly: layer), let source = sourceLayers[native], source.type == .routing,
              let declared = source.width, source.direction != nil else {
            throw PhysicalDesignRoutingSourceError(code: "routing_layer_semantics_missing", message: "Layer \(layer) requires exact source WIDTH and DIRECTION.")
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Only source routing owns complete generated-metal AREA admission and bounded repair. Other API/CLI conductor constructors must refuse AREA until they compose the same final component check.
        guard source.area == nil || areaHandledSeparately else {
            throw PhysicalDesignRoutingSourceError(code: "routing_layer_rules_unsupported", message: "This conductor mutation does not own source AREA admission.")
        }
        let actual = try PhysicalDesignProcessInputs.dbu(declared, units: units, field: "\(source.name).WIDTH")
        let width = width ?? actual
        guard (explicitSpecialWidth || width == actual), actual > 0, width > 0, width.isMultiple(of: 2) else {
            throw PhysicalDesignRoutingSourceError(code: "routing_width_unsupported", message: "Conductor width must match the even exact declared default WIDTH of \(source.name).")
        }
        if let minimum = source.minwidth, width < (try PhysicalDesignProcessInputs.dbu(minimum, units: units, field: "MINWIDTH")) {
            throw PhysicalDesignRoutingSourceError(code: "routing_width_unsupported", message: "Declared WIDTH violates MINWIDTH.")
        }
        if let maximum = source.maxwidth, width > (try PhysicalDesignProcessInputs.dbu(maximum, units: units, field: "MAXWIDTH")) {
            throw PhysicalDesignRoutingSourceError(code: "routing_width_unsupported", message: "Declared WIDTH violates MAXWIDTH.")
        }
        guard let rule = routingSpacingRules[native] else {
            throw PhysicalDesignRoutingSourceError(code: "routing_layer_semantics_missing", message: "Layer \(layer) requires a source spacing rule.")
        }
        let spacing = try rule.spacing(maximumWidth: width, parallelLength: .min)
        return (width, spacing)
    }

    // FIXME(INCOMPLETE_IMPLEMENTATION): Stages other than source routing and CTS still require their own final AREA admission before this capability gate can be removed.
    func validateAreaStage(_ request: PhysicalDesignRequest, snapshot: PhysicalDesignSnapshot) throws {
        guard !routingMinimumAreas.isEmpty else { return }
        let sourceRouting = request.stage == .globalRouting || request.stage == .detailedRouting
            || (request.stage == .timingECO && request.configuration.ecoAction == .rerouteNet)
        if sourceRouting { return }
        if request.stage == .clockTreeSynthesis {
            try validateCTSMetalAreas(snapshot)
            return
        }
        let geometryOnly = request.stage == .floorplan || request.stage == .placement
        guard geometryOnly, snapshot.routes.isEmpty, snapshot.vias.isEmpty,
              snapshot.powerStructures.isEmpty, snapshot.fills.isEmpty else {
            throw PhysicalDesignTechnologyError.unsupported("This stage does not own complete generated-metal AREA admission.")
        }
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
