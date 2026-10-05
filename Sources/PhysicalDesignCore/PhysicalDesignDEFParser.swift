import Foundation
import CircuiteFoundation
import LEF
import DEF

public struct PhysicalDesignDEFParser: Sendable {
    public static let parserID = "physical-design-def-parser"
    public static let parserVersion = "3.0.0"

    public init() {}

    public func parse(_ data: Data, cellMasters: [LEFMacroDef] = []) -> PhysicalDesignDEFParseResult {
        parseResolved(data, cellMasters: cellMasters).result
    }

    func parseResolved(_ data: Data, cellMasters: [LEFMacroDef] = [],
        processFactory: (@Sendable (Int) throws -> PhysicalDesignProcessGeometry)? = nil
    ) -> (result: PhysicalDesignDEFParseResult, geometry: PhysicalDesignProcessGeometry?) {
        guard let source = String(data: data, encoding: .utf8) else {
            return (PhysicalDesignDEFParseResult(
                snapshot: nil,
                diagnostics: [PhysicalDesignDEFDiagnostic(
                    severity: .error,
                    code: "def_invalid_utf8",
                    message: "DEF input is not valid UTF-8.",
                    line: 1,
                    section: "header",
                    suggestedActions: ["provide_utf8_encoded_def"]
                )]
            ), nil)
        }
        var state = State(masterGeometry: PhysicalDesignMasterGeometry(cellMasters), processFactory: processFactory)
        state.parse(source)
        return (state.result(), state.processGeometry)
    }

    private struct State {
        let masterGeometry: PhysicalDesignMasterGeometry
        let processFactory: (@Sendable (Int) throws -> PhysicalDesignProcessGeometry)?
        var processGeometry: PhysicalDesignProcessGeometry?
        private var tokens: [PhysicalDesignDEFToken] = []
        private var index = 0
        private var diagnostics: [PhysicalDesignDEFDiagnostic] = []
        private var topCell: String?
        private var unitsPerMicron = 1_000
        private var die: PhysicalDesignSnapshot.Rect?
        private var rows: [PhysicalDesignSnapshot.Row] = []
        private var tracks: [PhysicalDesignImplementationState.Track] = []
        private var cells: [PhysicalDesignSnapshot.Cell] = []
        private var pins: [PhysicalDesignSnapshot.Pin] = []
        private var pads: [PhysicalDesignImplementationState.Pad] = []
        private var nets: [PhysicalDesignSnapshot.Net] = []
        private var blockages: [PhysicalDesignSnapshot.Rect] = []
        private var powerStructures: [PhysicalDesignSnapshot.PowerStructure] = []
        private var routes: [PhysicalDesignSnapshot.Route] = []
        private var pinIndexByKey: [String: Int] = [:]
        private var topPinNameToID: [String: String] = [:]
        private var hasUnits = false
        private var hasVersion = false
        private var hasDesign = false
        private var hasDieArea = false
        private var finishedDesign = false

        mutating func parse(_ source: String) {
            tokens = PhysicalDesignDEFLexer().lex(source)
            while !isAtEnd, !finishedDesign {
                let token = consume()
                switch token.text.uppercased() {
                case "VERSION":
                    parseVersion()
                case "DIVIDERCHAR", "BUSBITCHARS":
                    _ = readStatementTokens()
                case "DESIGN":
                    parseDesign(token)
                case "UNITS":
                    parseUnits(token)
                case "DIEAREA":
                    parseDieArea(token)
                case "ROW":
                    parseRow(token)
                case "TRACKS":
                    parseTrack(token)
                case "COMPONENTS":
                    parseComponents(token)
                case "PINS":
                    parsePins(token)
                case "NETS":
                    parseNets(token)
                case "BLOCKAGES":
                    parseBlockages(token)
                case "SPECIALNETS":
                    parseSpecialNets(token)
                case "END":
                    parseTopLevelEnd(token)
                default:
                    addDiagnostic(
                        severity: processFactory == nil ? .warning : .error,
                        code: "def_unsupported_section",
                        message: "DEF statement or section \(token.text) is outside the supported interchange subset.",
                        token: token,
                        section: "header",
                        suggestedActions: ["convert_the_input_to_the_supported_def_subset"]
                    )
                    skipUnsupportedStatement(named: token.text)
                }
            }

            if processFactory != nil, !hasVersion || !hasUnits || !finishedDesign || !isAtEnd {
                addDiagnostic(severity: .error, code: "def_process_header_incomplete", message: "Process-bound DEF requires explicit VERSION/UNITS, END DESIGN and no trailing statements.",
                    line: firstLine, section: "header", suggestedActions: ["supply_a_complete_exact_def_header"])
            }

            if !hasDesign {
                addDiagnostic(
                    severity: .error,
                    code: "def_design_missing",
                    message: "DEF input does not declare a DESIGN name.",
                    line: firstLine,
                    section: "header",
                    suggestedActions: ["add_a_design_statement"]
                )
            }
            if !hasDieArea {
                addDiagnostic(
                    severity: .warning,
                    code: "def_diearea_missing",
                    message: "DEF input does not declare a DIEAREA; the canonical snapshot will have no die geometry.",
                    line: firstLine,
                    section: "header",
                    suggestedActions: ["add_a_diearea_statement"]
                )
            }
        }

        func result() -> PhysicalDesignDEFParseResult {
            guard let topCell, !topCell.isEmpty, !diagnostics.contains(where: { $0.severity == .error }) else {
                return PhysicalDesignDEFParseResult(snapshot: nil, diagnostics: diagnostics)
            }

            var resultDiagnostics = diagnostics
            let inferredCore: PhysicalDesignSnapshot.Rect?
            do { inferredCore = try coreInferredFromRows() }
            catch {
                resultDiagnostics.append(.init(severity: .error, code: "def_row_geometry_invalid", message: error.localizedDescription,
                    line: firstLine, section: "ROW", suggestedActions: ["repair_representable_row_extents"]))
                return PhysicalDesignDEFParseResult(snapshot: nil, diagnostics: resultDiagnostics)
            }
            if inferredCore != nil, !rows.isEmpty {
                resultDiagnostics.append(PhysicalDesignDEFDiagnostic(
                    severity: .warning,
                    code: "def_core_inferred_from_rows",
                    message: "Core geometry was inferred from the ROW extents because DEF does not carry an independent core rectangle.",
                    line: firstLine,
                    section: "ROW",
                    suggestedActions: ["verify_row_extents_against_the_process_floorplan"]
                ))
            }
            let snapshot = PhysicalDesignSnapshot(
                topCell: topCell,
                unitsPerMicron: unitsPerMicron,
                die: die,
                core: inferredCore,
                rows: rows.sorted { $0.id < $1.id },
                cells: cells.sorted { $0.id < $1.id },
                pins: pins.sorted { $0.id < $1.id },
                nets: nets.sorted { $0.id < $1.id },
                blockages: blockages.sorted { lhs, rhs in
                    (lhs.x, lhs.y, lhs.width, lhs.height) < (rhs.x, rhs.y, rhs.width, rhs.height)
                },
                powerStructures: powerStructures.sorted { $0.id < $1.id },
                routes: routes.sorted { $0.id < $1.id },
                implementationState: implementationState(),
                processManifest: processGeometry?.manifestReference,
                processAssets: processGeometry?.sources ?? [:]
            )
            let snapshotDiagnostics = snapshot.validationDiagnostics()
            if !snapshotDiagnostics.isEmpty {
                resultDiagnostics.append(contentsOf: snapshotDiagnostics.map { message in
                    PhysicalDesignDEFDiagnostic(
                        severity: .error,
                        code: "def_canonical_snapshot_invalid",
                        message: message,
                        line: firstLine,
                        section: "canonical-snapshot",
                        suggestedActions: ["repair_the_def_connectivity_and_geometry"]
                    )
                })
                return PhysicalDesignDEFParseResult(snapshot: nil, diagnostics: resultDiagnostics)
            }
            return PhysicalDesignDEFParseResult(snapshot: snapshot, diagnostics: resultDiagnostics)
        }

        private var isAtEnd: Bool { index >= tokens.count }

        private var firstLine: Int {
            tokens.first?.line ?? 1
        }

        private func peek(_ offset: Int = 0) -> PhysicalDesignDEFToken? {
            let position = index + offset
            guard position < tokens.count else { return nil }
            return tokens[position]
        }

        private mutating func consume() -> PhysicalDesignDEFToken {
            let token = tokens[index]
            index += 1
            return token
        }

        private mutating func readStatementTokens() -> [PhysicalDesignDEFToken] {
            var statement: [PhysicalDesignDEFToken] = []
            while !isAtEnd {
                let token = consume()
                if token.text == ";" {
                    return statement
                }
                statement.append(token)
            }
            if let token = statement.last {
                addDiagnostic(
                    severity: .error,
                    code: "def_statement_terminator_missing",
                    message: "DEF statement is missing its terminating semicolon.",
                    token: token,
                    section: "header",
                    suggestedActions: ["terminate_each_def_statement_with_a_semicolon"]
                )
            }
            return statement
        }

        private mutating func parseVersion() {
            let statement = readStatementTokens()
            if processFactory != nil, hasVersion || statement.count != 1 {
                addDiagnostic(severity: .error, code: "def_process_version_unsupported", message: "Process-bound DEF requires one exact VERSION declaration.",
                    token: statement.first ?? tokens[max(0, index - 1)], section: "header", suggestedActions: ["declare_one_exact_def_version"])
                return
            }
            hasVersion = true
            guard let version = statement.first else { return }
            if version.text != "5.8" {
                addDiagnostic(
                    severity: processFactory == nil ? .warning : .error,
                    code: "def_version_not_qualified",
                    message: "DEF version \(version.text) is parsed using the supported 5.8 subset.",
                    token: version,
                    section: "header",
                    suggestedActions: ["use_def_version_5.8_for_qualified_interchange"]
                )
            }
        }

        private mutating func parseDesign(_ token: PhysicalDesignDEFToken) {
            let statement = readStatementTokens()
            if processFactory != nil, hasDesign || statement.count != 1 {
                addDiagnostic(severity: .error, code: "def_process_design_unsupported", message: "Process-bound DEF requires one exact DESIGN declaration.",
                    token: token, section: "header", suggestedActions: ["declare_one_exact_design_name"])
                return
            }
            guard let name = statement.first, !name.text.isEmpty else {
                addDiagnostic(
                    severity: .error,
                    code: "def_design_name_missing",
                    message: "DESIGN does not contain a top-cell name.",
                    token: token,
                    section: "header",
                    suggestedActions: ["provide_a_design_name"]
                )
                return
            }
            topCell = name.text
            hasDesign = true
        }

        private mutating func parseUnits(_ token: PhysicalDesignDEFToken) {
            let statement = readStatementTokens()
            if processFactory != nil, statement.count != 3 || statement[0].text.uppercased() != "DISTANCE" || statement[1].text.uppercased() != "MICRONS" {
                addDiagnostic(severity: .error, code: "def_process_units_unsupported", message: "Process-bound DEF requires exact UNITS DISTANCE MICRONS syntax.",
                    token: token, section: "header", suggestedActions: ["declare_one_exact_units_scale"])
                return
            }
            guard let micronIndex = statement.firstIndex(where: { $0.text.uppercased() == "MICRONS" }), micronIndex + 1 < statement.count else {
                addDiagnostic(
                    severity: .error,
                    code: "def_units_missing",
                    message: "UNITS must declare DISTANCE MICRONS followed by an integer scale.",
                    token: token,
                    section: "header",
                    suggestedActions: ["declare_integer_microns_units"]
                )
                return
            }
            guard let value = integer(statement[micronIndex + 1], section: "header") else { return }
            guard value > 0, value <= Int64(Int.max) else {
                addDiagnostic(
                    severity: .error,
                    code: "def_units_invalid",
                    message: "UNITS scale must be a positive platform integer.",
                    token: statement[micronIndex + 1],
                    section: "header",
                    suggestedActions: ["use_a_positive_units_scale"]
                )
                return
            }
            guard !hasUnits, cells.isEmpty else {
                addDiagnostic(severity: .error, code: "def_units_conflicting",
                    message: "DEF units must be declared once before component geometry.",
                    token: token, section: "header", suggestedActions: ["declare_one_exact_units_scale"])
                return
            }
            unitsPerMicron = Int(value)
            hasUnits = true
            if let processFactory {
                do { processGeometry = try processFactory(unitsPerMicron) }
                catch { addDiagnostic(severity: .error, code: "def_process_geometry_unresolved", message: error.localizedDescription,
                    token: token, section: "header", suggestedActions: ["supply_exact_representable_process_views"]) }
            }
        }

        private mutating func parseDieArea(_ token: PhysicalDesignDEFToken) {
            let statement = readStatementTokens()
            if processFactory != nil, hasDieArea || statement.count != 8 {
                addDiagnostic(severity: .error, code: "def_process_die_unsupported", message: "The process-bound profile requires one rectangular DIEAREA declaration.",
                    token: token, section: "DIEAREA", suggestedActions: ["declare_one_exact_rectangular_die"])
                return
            }
            guard let rect = rectangle(from: statement, section: "DIEAREA") else {
                addDiagnostic(
                    severity: .error,
                    code: "def_diearea_invalid",
                    message: "DIEAREA must contain two coordinate pairs describing a positive rectangle.",
                    token: token,
                    section: "DIEAREA",
                    suggestedActions: ["repair_diearea_coordinate_pairs"]
                )
                return
            }
            die = rect
            hasDieArea = true
        }

        private mutating func parseRow(_ token: PhysicalDesignDEFToken) {
            let statement = readStatementTokens()
            guard statement.count >= 5, let id = statement.first else {
                addDiagnostic(
                    severity: .error,
                    code: "def_row_invalid",
                    message: "ROW does not contain the required site, origin and step fields.",
                    token: token,
                    section: "ROW",
                    suggestedActions: ["provide_a_complete_row_statement"]
                )
                return
            }
            guard let originX = integer(statement[2], section: "ROW"), let originY = integer(statement[3], section: "ROW") else { return }
            let uppercased = statement.map { $0.text.uppercased() }
            if processFactory != nil {
                guard statement.count == 12, let processGeometry, let site = processGeometry.sites[statement[1].text],
                      let orientation = DEFOrientation(rawValue: uppercased[4]),
                      let doIndex = uppercased.firstIndex(of: "DO"), doIndex == 5,
                      uppercased[doIndex + 2] == "BY", let count = integer(statement[doIndex + 1], section: "ROW"), count > 0,
                      statement[doIndex + 3].text == "1",
                      let stepIndex = uppercased.firstIndex(of: "STEP"), stepIndex == 9,
                      let stepX = integer(statement[stepIndex + 1], section: "ROW"),
                      let stepY = integer(statement[stepIndex + 2], section: "ROW"), stepY == 0 else {
                    addDiagnostic(severity: .error, code: "def_process_row_unresolved", message: "ROW requires explicit units, one declared site/orientation, BY 1 and STEP-y 0 for the current native profile.",
                        token: token, section: "ROW", suggestedActions: ["supply_exact_supported_site_repetition"])
                    return
                }
                let rotated = [DEFOrientation.e, .w, .fe, .fw].contains(orientation)
                let width = rotated ? site.height : site.width
                let height = rotated ? site.width : site.height
                let (extent, extentOverflow) = width.multipliedReportingOverflow(by: count)
                let (_, xOverflow) = originX.addingReportingOverflow(extent)
                let (_, yOverflow) = originY.addingReportingOverflow(height)
                guard (stepX == width || (count == 1 && stepX == 0)), !extentOverflow, !xOverflow, !yOverflow else {
                    addDiagnostic(severity: .error, code: "def_process_row_unresolved", message: "ROW repetition must match exact oriented SITE width and representable extents.",
                        token: token, section: "ROW", suggestedActions: ["repair_site_pitch_and_row_extents"])
                    return
                }
                rows.append(.init(id: id.text, originX: originX, originY: originY, siteWidth: width, height: height, siteCount: count,
                    siteName: statement[1].text, orientation: orientation))
                return
            }
            guard let doIndex = uppercased.firstIndex(of: "DO"), doIndex + 1 < statement.count,
                  let siteCount = integer(statement[doIndex + 1], section: "ROW"),
                  let stepIndex = uppercased.firstIndex(of: "STEP"), stepIndex + 2 < statement.count,
                  let siteWidth = integer(statement[stepIndex + 1], section: "ROW"),
                  let height = integer(statement[stepIndex + 2], section: "ROW") else {
                addDiagnostic(
                    severity: .error,
                    code: "def_row_geometry_invalid",
                    message: "ROW requires DO count and STEP site-width/height integers.",
                    token: token,
                    section: "ROW",
                    suggestedActions: ["repair_row_do_and_step_fields"]
                )
                return
            }
            rows.append(PhysicalDesignSnapshot.Row(
                id: id.text,
                originX: originX,
                originY: originY,
                siteWidth: siteWidth,
                height: height,
                siteCount: siteCount
            ))
        }

        private mutating func parseTrack(_ token: PhysicalDesignDEFToken) {
            let statement = readStatementTokens()
            let uppercased = statement.map { $0.text.uppercased() }
            guard let axis = statement.first, statement.count >= 8,
                  let origin = integer(statement[1], section: "TRACKS"),
                  let doIndex = uppercased.firstIndex(of: "DO"), doIndex + 1 < statement.count,
                  let count = integer(statement[doIndex + 1], section: "TRACKS"),
                  let stepIndex = uppercased.firstIndex(of: "STEP"), stepIndex + 1 < statement.count,
                  let spacing = integer(statement[stepIndex + 1], section: "TRACKS"),
                  let layerIndex = uppercased.firstIndex(of: "LAYER"), layerIndex + 1 < statement.count,
                  let layer = parseLayer(statement[layerIndex + 1]) else {
                addDiagnostic(
                    severity: .error,
                    code: "def_track_invalid",
                    message: "TRACKS requires an axis, origin, count, spacing and layer.",
                    token: token,
                    section: "TRACKS",
                    suggestedActions: ["provide_a_complete_tracks_statement"]
                )
                return
            }
            let direction = axis.text.uppercased() == "X" ? "vertical" : "horizontal"
            if processFactory != nil, (!["X", "Y"].contains(axis.text.uppercased()) || statement.count != 8 || doIndex != 2 || stepIndex != 4 || layerIndex != 6) {
                addDiagnostic(severity: .error, code: "def_process_track_unsupported", message: "The current process-bound TRACKS profile requires one X/Y axis and one exact layer.",
                    token: token, section: "TRACKS", suggestedActions: ["split_tracks_by_declared_layer"])
                return
            }
            tracks.append(PhysicalDesignImplementationState.Track(
                id: "track_M\(layer)_\(axis.text.uppercased())",
                layer: layer,
                direction: direction,
                origin: origin,
                spacing: spacing,
                count: count
            ))
        }

        private mutating func parseComponents(_ token: PhysicalDesignDEFToken) {
            guard let expectedCount = beginSection(named: "COMPONENTS", token: token) else { return }
            var actualCount = 0
            while !isAtEnd {
                if isEndSection(named: "COMPONENTS") {
                    consumeEndSection(named: "COMPONENTS")
                    break
                }
                guard consumeSectionMarker(named: "COMPONENTS") else { continue }
                let item = readStatementTokens()
                parseComponent(item)
                actualCount += 1
            }
            finishSection(named: "COMPONENTS", expectedCount: expectedCount, actualCount: actualCount, token: token)
        }

        private mutating func parseComponent(_ item: [PhysicalDesignDEFToken]) {
            guard item.count >= 2 else {
                addDiagnostic(
                    severity: .error,
                    code: "def_component_invalid",
                    message: "COMPONENT record requires an instance identifier and master name.",
                    token: item.first ?? tokens[max(0, index - 1)],
                    section: "COMPONENTS",
                    suggestedActions: ["provide_component_instance_and_master"]
                )
                return
            }
            let id = item[0].text
            let master = item[1].text
            if processFactory != nil {
                let clauses = item.indices.filter { item[$0].text == "+" }
                let bareUnplaced = clauses.isEmpty && item.count == 2
                let placedClause = clauses.count == 1 && clauses.first == 2 && item.count == 9 && ["PLACED", "FIXED"].contains(item[3].text.uppercased())
                let unplacedClause = clauses.count == 1 && clauses.first == 2 && item.count == 4 && item[3].text.uppercased() == "UNPLACED"
                guard bareUnplaced || placedClause || unplacedClause else {
                    addDiagnostic(severity: .error, code: "def_process_component_unsupported", message: "The process-bound component profile retains one PLACED/FIXED/UNPLACED clause; other attributes require exact standard interchange.",
                        token: item[0], section: "COMPONENTS", entity: id, suggestedActions: ["provide_supported_exact_component_attributes"])
                    return
                }
            }
            var x: Int64 = 0
            var y: Int64 = 0
            var widths: [Int64] = []
            var heights: [Int64] = []
            var placed = false
            var locked = false
            var hasPlacement = false
            var orientation: DEFOrientation = .n
            let uppercased = item.map { $0.text.uppercased() }
            for position in item.indices {
                if uppercased[position] == "PLACED" || uppercased[position] == "FIXED" || uppercased[position] == "COVER" {
                    placed = true
                    locked = uppercased[position] == "FIXED"
                    if position + 1 < item.count, let point = coordinatePair(in: item, start: position + 1, section: "COMPONENTS") {
                        x = point.0
                        y = point.1
                        hasPlacement = true
                        guard position + 5 < item.count, let parsedOrientation = DEFOrientation(rawValue: uppercased[position + 5]) else {
                            addDiagnostic(severity: .error, code: "def_component_orientation_unsupported",
                                message: "Component \(id) requires an explicit standard orientation.",
                                token: item[position], section: "COMPONENTS", entity: id,
                                suggestedActions: ["provide_supported_orientation_or_implement_exact_process_transforms"])
                            return
                        }
                        orientation = parsedOrientation
                        // FIXME(INCOMPLETE_IMPLEMENTATION): Unqualified DEF dimension-only imports support N only. Other orientations require exact source port/OBS/site projection; API callers must provide process sources through the executor until full independent interchange is implemented.
                        if processFactory == nil, orientation != .n {
                            addDiagnostic(severity: .error, code: "def_component_orientation_unsupported",
                                message: "Component \(id) requires source-bound orientation geometry.", token: item[position], section: "COMPONENTS", entity: id,
                                suggestedActions: ["provide_exact_process_sources"])
                            return
                        }
                    }
                }
                if uppercased[position] == "SIZE", position + 3 < item.count,
                   let parsedWidth = integer(item[position + 1], section: "COMPONENTS"),
                   uppercased[position + 2] == "BY",
                   let parsedHeight = integer(item[position + 3], section: "COMPONENTS") {
                    widths.append(parsedWidth)
                    heights.append(parsedHeight)
                }
                if uppercased[position] == "XCI_CELL_WIDTH", position + 1 < item.count,
                   let parsedWidth = integer(item[position + 1], section: "COMPONENTS") {
                    widths.append(parsedWidth)
                }
                if uppercased[position] == "XCI_CELL_HEIGHT", position + 1 < item.count,
                   let parsedHeight = integer(item[position + 1], section: "COMPONENTS") {
                    heights.append(parsedHeight)
                }
            }
            if !hasPlacement {
                addDiagnostic(
                    severity: .warning,
                    code: "def_component_placement_missing",
                    message: "Component \(id) has no PLACED/FIXED coordinate pair; origin (0, 0) is used.",
                    token: item[0],
                    section: "COMPONENTS",
                    entity: id,
                    suggestedActions: ["provide_component_placement_or_mark_it_unplaced"]
                )
            }
            guard widths.count <= 1, heights.count <= 1, (masterGeometry.isEmpty && processFactory == nil) || hasUnits else {
                addDiagnostic(severity: .error, code: "def_cell_geometry_unresolved",
                    message: "Component \(id) requires unique dimensions and explicit DEF units for master resolution.",
                    token: item[0], section: "COMPONENTS", entity: id,
                    suggestedActions: ["declare_exact_units_and_remove_duplicate_dimensions"])
                return
            }
            var width = widths.first
            var height = heights.first
            if !masterGeometry.isEmpty || processFactory != nil {
                do {
                    let resolved: (width: Int64, height: Int64)
                    if let processGeometry { resolved = try processGeometry.dimensions(master: master, orientation: orientation) }
                    else {
                        guard processFactory == nil else { throw PhysicalDesignTechnologyError.invalid("Explicit units and exact process projection are required before component geometry.") }
                        resolved = try masterGeometry.dimensions(of: master, units: unitsPerMicron)
                    }
                    guard (width == nil || width == resolved.width), (height == nil || height == resolved.height) else {
                        throw PhysicalDesignTechnologyError.invalid("Explicit DEF dimensions contradict LEF master \(master).")
                    }
                    width = resolved.width
                    height = resolved.height
                } catch {
                    addDiagnostic(severity: .error, code: "def_cell_geometry_unresolved",
                        message: error.localizedDescription, token: item[0], section: "COMPONENTS", entity: id,
                        suggestedActions: ["provide_one_exact_master_with_grid_representable_size"])
                    return
                }
            }
            guard let width, let height else {
                addDiagnostic(severity: .error, code: "def_cell_geometry_unresolved",
                    message: "Component \(id) requires an exact LEF master or complete explicit geometry-smoke dimensions.",
                    token: item[0], section: "COMPONENTS", entity: id,
                    suggestedActions: ["supply_the_exact_cell_library"])
                return
            }
            if cells.contains(where: { $0.id == id }) {
                addDiagnostic(
                    severity: .error,
                    code: "def_duplicate_component",
                    message: "Component identifier \(id) is declared more than once.",
                    token: item[0],
                    section: "COMPONENTS",
                    entity: id,
                    suggestedActions: ["use_unique_component_identifiers"]
                )
                return
            }
            cells.append(PhysicalDesignSnapshot.Cell(
                id: id,
                master: master,
                x: x,
                y: y,
                width: width,
                height: height,
                placed: placed,
                locked: locked,
                orientation: orientation
            ))
        }

        private mutating func parsePins(_ token: PhysicalDesignDEFToken) {
            guard let expectedCount = beginSection(named: "PINS", token: token) else { return }
            var actualCount = 0
            while !isAtEnd {
                if isEndSection(named: "PINS") {
                    consumeEndSection(named: "PINS")
                    break
                }
                guard consumeSectionMarker(named: "PINS") else { continue }
                let item = readStatementTokens()
                if processFactory != nil { parseExactTopPin(item) }
                else { parsePin(item) }
                actualCount += 1
            }
            finishSection(named: "PINS", expectedCount: expectedCount, actualCount: actualCount, token: token)
        }

        private mutating func parseExactTopPin(_ item: [PhysicalDesignDEFToken]) {
            guard let nameToken = item.first else { return }
            do {
                guard topPinNameToID[nameToken.text] == nil else { throw PhysicalDesignTechnologyError.invalid("Duplicate top-level pin identity.") }
                var position = 1
                var seen: Set<String> = []
                var net: String?
                var direction: DEFPin.Direction?
                var use: DEFSpecialNet.NetUse?
                var layer: Int?
                var rectangle: PhysicalDesignSnapshot.Rect?
                var placement: (Int64, Int64)?
                var orientation: DEFOrientation?
                var status: DEFComponent.PlacementStatus?
                func take() throws -> PhysicalDesignDEFToken {
                    guard position < item.count else { throw PhysicalDesignTechnologyError.invalid("Incomplete exact top-port clause.") }
                    defer { position += 1 }
                    return item[position]
                }
                func point() throws -> (Int64, Int64) {
                    let open = try take(), x = try take(), y = try take(), close = try take()
                    guard open.text == "(", close.text == ")", let px = Int64(x.text), let py = Int64(y.text),
                          Int32(exactly: px) != nil, Int32(exactly: py) != nil else {
                        throw PhysicalDesignTechnologyError.invalid("Top-port coordinates require exact Int32 DBU pairs.")
                    }
                    return (px, py)
                }
                while position < item.count {
                    guard try take().text == "+" else { throw PhysicalDesignTechnologyError.unsupported("Top-port attributes require the supported single-RECT profile.") }
                    let clause = try take().text.uppercased()
                    let key = ["PLACED", "FIXED", "COVER"].contains(clause) ? "placement" : clause
                    guard seen.insert(key).inserted else { throw PhysicalDesignTechnologyError.unsupported("Repeated top-port attribute or surface.") }
                    switch clause {
                    case "NET": net = try take().text
                    case "DIRECTION":
                        direction = DEFPin.Direction(rawValue: try take().text.uppercased())
                    case "USE": use = DEFSpecialNet.NetUse(rawValue: try take().text.uppercased())
                    case "LAYER":
                        let token = try take()
                        guard let mapped = parseLayer(token) else { throw PhysicalDesignTechnologyError.invalid("Top-port layer has no exact process mapping.") }
                        layer = mapped
                        let a = try point(), b = try point()
                        rectangle = .init(x: a.0, y: a.1, width: b.0 - a.0, height: b.1 - a.1)
                    case "PLACED", "FIXED", "COVER":
                        status = DEFComponent.PlacementStatus(rawValue: clause)
                        placement = try point()
                        orientation = DEFOrientation(rawValue: try take().text.uppercased())
                    default:
                        throw PhysicalDesignTechnologyError.unsupported("Top-port attribute \(clause) is outside the exact single-RECT profile.")
                    }
                }
                guard let net, !net.isEmpty, net != "UNCONNECTED", let direction, let use,
                      let layer, let rectangle, let placement, let orientation, let status else {
                    throw PhysicalDesignTechnologyError.invalid("Exact top-port NET/DIRECTION/USE/LAYER/RECT and placement pose are required.")
                }
                let port = PhysicalDesignTopPort(rectangle: rectangle, layer: layer,
                    placementX: placement.0, placementY: placement.1, orientation: orientation,
                    placementStatus: status, use: use)
                let world = try port.worldRectangle()
                // Access metadata is derived from actual source geometry, never from a
                // nearest wire, width or pad. The original pose stays separately retained.
                let containsOrigin = world.containsPoint(x: placement.0, y: placement.1)
                let id = "pin_\(nameToken.text)"
                topPinNameToID[nameToken.text] = id
                pinIndexByKey[pinKey(cellID: nil, name: nameToken.text)] = pins.count
                pins.append(.init(id: id, name: nameToken.text,
                    x: containsOrigin ? placement.0 : world.x, y: containsOrigin ? placement.1 : world.y,
                    netID: net, direction: direction.rawValue.lowercased(), accessLayer: layer, topPort: port))
            } catch {
                addDiagnostic(severity: .error, code: "def_process_top_port_invalid", message: String(describing: error),
                    token: nameToken, section: "PINS", entity: nameToken.text,
                    suggestedActions: ["provide_exact_single_rect_top_port_and_source_bindings"])
            }
        }

        // FIXME(INCOMPLETE_IMPLEMENTATION): Source-free geometry-smoke DEF intake retains point-only pins. Exact physical top-port interchange requires the process-bound branch and real source RECT/pose; this smoke path cannot establish it.
        private mutating func parsePin(_ item: [PhysicalDesignDEFToken]) {
            guard let nameToken = item.first else { return }
            let name = nameToken.text
            let id = "pin_\(name)"
            if topPinNameToID[name] != nil {
                addDiagnostic(
                    severity: .error,
                    code: "def_duplicate_pin",
                    message: "Top-level pin \(name) is declared more than once.",
                    token: nameToken,
                    section: "PINS",
                    entity: name,
                    suggestedActions: ["use_unique_top_level_pin_names"]
                )
                return
            }
            var netID: String?
            var direction = "input"
            var x: Int64 = 0
            var y: Int64 = 0
            var padSide: String?
            var padX: Int64?
            var padY: Int64?
            var padWidth: Int64?
            var padHeight: Int64?
            let uppercased = item.map { $0.text.uppercased() }
            if let netIndex = uppercased.firstIndex(of: "NET"), netIndex + 1 < item.count {
                netID = item[netIndex + 1].text
            }
            if let directionIndex = uppercased.firstIndex(of: "DIRECTION"), directionIndex + 1 < item.count {
                direction = item[directionIndex + 1].text.lowercased()
            }
            if let propertyIndex = uppercased.firstIndex(of: "XCI_PAD_SIDE"), propertyIndex + 1 < item.count {
                padSide = item[propertyIndex + 1].text.lowercased()
            }
            if let propertyIndex = uppercased.firstIndex(of: "XCI_PAD_X"), propertyIndex + 1 < item.count {
                padX = integer(item[propertyIndex + 1], section: "PINS")
            }
            if let propertyIndex = uppercased.firstIndex(of: "XCI_PAD_Y"), propertyIndex + 1 < item.count {
                padY = integer(item[propertyIndex + 1], section: "PINS")
            }
            if let propertyIndex = uppercased.firstIndex(of: "XCI_PAD_WIDTH"), propertyIndex + 1 < item.count {
                padWidth = integer(item[propertyIndex + 1], section: "PINS")
            }
            if let propertyIndex = uppercased.firstIndex(of: "XCI_PAD_HEIGHT"), propertyIndex + 1 < item.count {
                padHeight = integer(item[propertyIndex + 1], section: "PINS")
            }
            for position in item.indices where uppercased[position] == "PLACED" || uppercased[position] == "FIXED" || uppercased[position] == "COVER" {
                if position + 1 < item.count, let point = coordinatePair(in: item, start: position + 1, section: "PINS") {
                    x = point.0
                    y = point.1
                }
            }
            topPinNameToID[name] = id
            pinIndexByKey[pinKey(cellID: nil, name: name)] = pins.count
            pins.append(PhysicalDesignSnapshot.Pin(
                id: id,
                name: name,
                x: x,
                y: y,
                netID: netID,
                direction: direction
            ))
            if let padSide, let padX, let padY, let padWidth, let padHeight {
                pads.append(PhysicalDesignImplementationState.Pad(
                    id: "pad_\(id)",
                    pinID: id,
                    side: padSide,
                    geometry: PhysicalDesignSnapshot.Rect(x: padX, y: padY, width: padWidth, height: padHeight),
                    placed: true
                ))
            }
        }

        private mutating func parseNets(_ token: PhysicalDesignDEFToken) {
            guard let expectedCount = beginSection(named: "NETS", token: token) else { return }
            var actualCount = 0
            while !isAtEnd {
                if isEndSection(named: "NETS") {
                    consumeEndSection(named: "NETS")
                    break
                }
                guard consumeSectionMarker(named: "NETS") else { continue }
                let item = readStatementTokens()
                parseNet(item)
                actualCount += 1
            }
            finishSection(named: "NETS", expectedCount: expectedCount, actualCount: actualCount, token: token)
        }

        private mutating func parseNet(_ item: [PhysicalDesignDEFToken]) {
            guard let nameToken = item.first else { return }
            let netID = nameToken.text
            if nets.contains(where: { $0.id == netID }) {
                addDiagnostic(
                    severity: .error,
                    code: "def_duplicate_net",
                    message: "Net identifier \(netID) is declared more than once.",
                    token: nameToken,
                    section: "NETS",
                    entity: netID,
                    suggestedActions: ["use_unique_net_identifiers"]
                )
                return
            }
            var pinIDs: [String] = []
            var position = 1
            var declaredClock: Bool?
            while position < item.count {
                if position + 3 < item.count, item[position].text == "(", item[position + 3].text == ")",
                   processFactory != nil || (Int64(item[position + 1].text) == nil && Int64(item[position + 2].text) == nil) {
                    let cellName = item[position + 1].text
                    let pinName = item[position + 2].text
                    let pinID = ensurePin(cellID: cellName.uppercased() == "PIN" ? nil : cellName, name: pinName, token: item[position + 1])
                    if !pinIDs.contains(pinID) {
                        pinIDs.append(pinID)
                    } else if processFactory != nil {
                        addDiagnostic(severity: .error, code: "def_process_connection_duplicate", message: "A process-bound net cannot repeat one connection.",
                            token: item[position], section: "NETS", entity: netID, suggestedActions: ["declare_each_exact_connection_once"])
                    }
                    setNetID(netID, forPinID: pinID)
                    position += 4
                } else if processFactory != nil, position + 2 < item.count, item[position].text == "+",
                          item[position + 1].text.uppercased() == "USE", ["SIGNAL", "CLOCK"].contains(item[position + 2].text.uppercased()), declaredClock == nil {
                    declaredClock = item[position + 2].text.uppercased() == "CLOCK"
                    position += 3
                } else if processFactory != nil {
                    addDiagnostic(severity: .error, code: "def_process_net_unsupported", message: "Process-bound NETS currently retain exact connection pairs and one SIGNAL/CLOCK use only.",
                        token: item[position], section: "NETS", entity: netID, suggestedActions: ["provide_supported_exact_net_attributes"])
                    return
                } else {
                    position += 1
                }
            }
            if pinIDs.isEmpty {
                addDiagnostic(
                    severity: .warning,
                    code: "def_net_has_no_connections",
                    message: "Net \(netID) contains no supported component/pin connections.",
                    token: nameToken,
                    section: "NETS",
                    entity: netID,
                    suggestedActions: ["add_net_connection_pairs"]
                )
            }
            let routeRecords = parseRoutes(in: item, netID: netID)
            routes.append(contentsOf: routeRecords)
            nets.append(PhysicalDesignSnapshot.Net(
                id: netID,
                pinIDs: pinIDs.sorted(),
                isClock: processFactory == nil ? netID.lowercased().contains("clk") : declaredClock == true,
                routingClass: .regular, defUse: declaredClock.map { $0 ? .clock : .signal },
                antennaRatio: nil,
                maximumAntennaRatio: nil
            ))
        }

        private mutating func parseBlockages(_ token: PhysicalDesignDEFToken) {
            guard let expectedCount = beginSection(named: "BLOCKAGES", token: token) else { return }
            var actualCount = 0
            while !isAtEnd {
                if isEndSection(named: "BLOCKAGES") {
                    consumeEndSection(named: "BLOCKAGES")
                    break
                }
                guard consumeSectionMarker(named: "BLOCKAGES") else { continue }
                let item = readStatementTokens()
                if processFactory != nil, item.count != 10 || item.first?.text.uppercased() != "PLACEMENT" || item[1].text.uppercased() != "RECT" {
                    addDiagnostic(severity: .error, code: "def_process_blockage_unsupported", message: "The process-bound profile retains rectangular hard placement blockages only.",
                        token: item.first ?? token, section: "BLOCKAGES", suggestedActions: ["provide_supported_exact_blockage_geometry"])
                    actualCount += 1
                    continue
                }
                guard let rect = rectangle(from: item, section: "BLOCKAGES") else {
                    addDiagnostic(
                        severity: .error,
                        code: "def_blockage_invalid",
                        message: "BLOCKAGES record must contain two coordinate pairs.",
                        token: item.first ?? token,
                        section: "BLOCKAGES",
                        suggestedActions: ["repair_blockage_coordinate_pairs"]
                    )
                    actualCount += 1
                    continue
                }
                blockages.append(rect)
                actualCount += 1
            }
            finishSection(named: "BLOCKAGES", expectedCount: expectedCount, actualCount: actualCount, token: token)
        }

        private mutating func parseSpecialNets(_ token: PhysicalDesignDEFToken) {
            guard let expectedCount = beginSection(named: "SPECIALNETS", token: token) else { return }
            // FIXME(INCOMPLETE_IMPLEMENTATION): Native process-bound special-net import needs exact widths/vias/connectivity. Reject this API/CLI section until B6 retains the full standard contract.
            if processFactory != nil, expectedCount > 0 {
                addDiagnostic(severity: .error, code: "def_process_special_nets_unsupported", message: "Exact process-bound SPECIALNETS interchange is not complete.",
                    token: token, section: "SPECIALNETS", suggestedActions: ["provide_supported_exact_special_net_interchange"])
            }
            var actualCount = 0
            while !isAtEnd {
                if isEndSection(named: "SPECIALNETS") {
                    consumeEndSection(named: "SPECIALNETS")
                    break
                }
                guard consumeSectionMarker(named: "SPECIALNETS") else { continue }
                let item = readStatementTokens()
                parseSpecialNet(item, ordinal: actualCount, fallbackToken: token)
                actualCount += 1
            }
            finishSection(named: "SPECIALNETS", expectedCount: expectedCount, actualCount: actualCount, token: token)
        }

        private mutating func parseSpecialNet(_ item: [PhysicalDesignDEFToken], ordinal: Int, fallbackToken: PhysicalDesignDEFToken) {
            guard let netToken = item.first else { return }
            let netID = netToken.text
            let uppercased = item.map { $0.text.uppercased() }
            var kind = "power"
            if let useIndex = uppercased.firstIndex(of: "USE"), useIndex + 1 < item.count {
                kind = item[useIndex + 1].text.lowercased()
            }
            var structureID = "power_\(netID)_\(ordinal)"
            if let propertyIndex = uppercased.firstIndex(of: "XCI_POWER_ID"), propertyIndex + 1 < item.count {
                structureID = item[propertyIndex + 1].text
            }
            var layer = 0
            if let routedIndex = uppercased.firstIndex(of: "ROUTED"), routedIndex + 1 < item.count {
                layer = parseLayer(item[routedIndex + 1]) ?? 0
            }
            guard let geometry = rectangle(from: item, section: "SPECIALNETS") else {
                addDiagnostic(
                    severity: .error,
                    code: "def_power_structure_invalid",
                    message: "SPECIALNETS record \(netID) must contain a supported routed rectangle.",
                    token: item.first ?? fallbackToken,
                    section: "SPECIALNETS",
                    entity: structureID,
                    suggestedActions: ["provide_power_structure_layer_and_rectangle"]
                )
                return
            }
            powerStructures.append(PhysicalDesignSnapshot.PowerStructure(
                id: structureID,
                netID: netID,
                kind: kind,
                layer: layer,
                geometry: geometry
            ))
        }

        private mutating func parseTopLevelEnd(_ token: PhysicalDesignDEFToken) {
            guard let name = peek() else {
                addDiagnostic(
                    severity: .error,
                    code: "def_end_name_missing",
                    message: "END does not name the section or design being closed.",
                    token: token,
                    section: "header",
                    suggestedActions: ["provide_an_end_name"]
                )
                return
            }
            let endName = consume().text.uppercased()
            if endName == "DESIGN" {
                finishedDesign = true
            } else {
                addDiagnostic(
                    severity: .warning,
                    code: "def_unexpected_end",
                    message: "END \(name.text) appeared outside a supported section.",
                    token: token,
                    section: "header",
                    suggestedActions: ["keep_section_end_markers_balanced"]
                )
            }
        }

        private mutating func beginSection(named name: String, token: PhysicalDesignDEFToken) -> Int? {
            let header = readStatementTokens()
            guard let countToken = header.first, let count = integer(countToken, section: name), count >= 0 else {
                addDiagnostic(
                    severity: .error,
                    code: "def_section_count_invalid",
                    message: "\(name) section requires a non-negative record count.",
                    token: header.first ?? token,
                    section: name,
                    suggestedActions: ["provide_a_valid_section_record_count"]
                )
                return nil
            }
            return Int(count)
        }

        private mutating func finishSection(named name: String, expectedCount: Int, actualCount: Int, token: PhysicalDesignDEFToken) {
            guard expectedCount == actualCount else {
                addDiagnostic(
                    severity: .error,
                    code: "def_section_count_mismatch",
                    message: "\(name) declares \(expectedCount) records but contains \(actualCount).",
                    token: token,
                    section: name,
                    suggestedActions: ["repair_the_def_section_record_count"]
                )
                return
            }
        }

        private func isEndSection(named name: String) -> Bool {
            peek()?.text.uppercased() == "END" && peek(1)?.text.uppercased() == name
        }

        private mutating func consumeEndSection(named name: String) {
            let endToken = consume()
            guard !isAtEnd else {
                addDiagnostic(
                    severity: .error,
                    code: "def_section_end_name_missing",
                    message: "END in \(name) is missing its section name.",
                    token: endToken,
                    section: name,
                    suggestedActions: ["provide_the_matching_section_name"]
                )
                return
            }
            let actualName = consume()
            if actualName.text.uppercased() != name {
                addDiagnostic(
                    severity: .error,
                    code: "def_section_end_mismatch",
                    message: "Expected END \(name), found END \(actualName.text).",
                    token: actualName,
                    section: name,
                    suggestedActions: ["balance_def_section_end_markers"]
                )
            }
            if peek()?.text == ";" {
                _ = consume()
            }
        }

        private mutating func consumeSectionMarker(named section: String) -> Bool {
            guard let token = peek() else { return false }
            guard token.text == "-" else {
                addDiagnostic(
                    severity: .error,
                    code: "def_section_record_marker_missing",
                    message: "Expected a '-' record marker in \(section), found \(token.text).",
                    token: token,
                    section: section,
                    suggestedActions: ["repair_the_def_section_record_marker"]
                )
                _ = readStatementTokens()
                return false
            }
            _ = consume()
            return true
        }

        private mutating func skipUnsupportedStatement(named name: String) {
            while !isAtEnd {
                if peek()?.text == ";" {
                    _ = consume()
                    return
                }
                if peek()?.text.uppercased() == "END" {
                    _ = consume()
                    if !isAtEnd { _ = consume() }
                    if peek()?.text == ";" { _ = consume() }
                    return
                }
                _ = consume()
            }
            addDiagnostic(
                severity: .warning,
                code: "def_unsupported_statement_truncated",
                message: "Unsupported DEF statement \(name) reached end of input.",
                line: firstLine,
                section: "header",
                suggestedActions: ["use_a_complete_def_input"]
            )
        }

        private mutating func ensurePin(cellID: String?, name: String, token: PhysicalDesignDEFToken) -> String {
            let key = pinKey(cellID: cellID, name: name)
            if let existingIndex = pinIndexByKey[key] {
                return pins[existingIndex].id
            }
            if let cellID, !cells.contains(where: { $0.id == cellID }) {
                addDiagnostic(
                    severity: .error,
                    code: "def_net_component_missing",
                    message: "Net references undeclared component \(cellID).",
                    token: token,
                    section: "NETS",
                    entity: cellID,
                    suggestedActions: ["declare_the_component_before_using_it_in_a_net"]
                )
            }
            let id = cellID.map { "pin_\($0)_\(name)" } ?? topPinNameToID[name] ?? "pin_\(name)"
            let cell = cellID.flatMap { cellID in cells.first { $0.id == cellID } }
            if processFactory != nil {
                do {
                    guard let processGeometry, let cell else {
                        throw PhysicalDesignTechnologyError.invalid("Connected component pin \(cellID ?? "PIN")/\(name) requires one exact declared master port and direction.")
                    }
                    let resolved = try processGeometry.referencePin(.init(id: id, cellID: cell.id, name: name), for: cell)
                    pinIndexByKey[key] = pins.count
                    pins.append(resolved)
                } catch {
                    addDiagnostic(severity: .error, code: "def_process_pin_unresolved", message: error.localizedDescription, token: token,
                        section: "NETS", entity: id, suggestedActions: ["supply_exact_declared_master_pin_geometry"])
                }
                return id
            }
            // FIXME(INCOMPLETE_IMPLEMENTATION): Unqualified DEF API/interchange imports synthesize component pins at the cell origin. Exact source-bound imports use the branch above; independent unqualified interchange must fail or resolve real ports before it can support physical correctness.
            let pin = PhysicalDesignSnapshot.Pin(
                id: id,
                cellID: cellID,
                name: name,
                x: cell?.x ?? 0,
                y: cell?.y ?? 0,
                direction: "input"
            )
            pinIndexByKey[key] = pins.count
            pins.append(pin)
            return id
        }

        private mutating func setNetID(_ netID: String, forPinID pinID: String) {
            guard let pinIndex = pins.firstIndex(where: { $0.id == pinID }) else { return }
            if pins[pinIndex].topPort != nil, pins[pinIndex].netID != netID {
                addDiagnostic(severity: .error, code: "def_process_top_pin_net_mismatch", message: "Top-port NET contradicts its declared connection.",
                    line: firstLine, section: "NETS", entity: pinID, suggestedActions: ["align_the_exact_top_port_net_binding"])
                return
            }
            pins[pinIndex].netID = netID
        }

        private func pinKey(cellID: String?, name: String) -> String {
            "\(cellID ?? "PIN")::\(name)"
        }

        private func implementationState() -> PhysicalDesignImplementationState? {
            guard !tracks.isEmpty || !pads.isEmpty else { return nil }
            return PhysicalDesignImplementationState(
                tracks: tracks.sorted { $0.id < $1.id },
                pads: pads.sorted { $0.id < $1.id }
            )
        }

        private func coreInferredFromRows() throws -> PhysicalDesignSnapshot.Rect? {
            guard let firstRow = rows.first else { return nil }
            var minX = firstRow.originX
            var minY = firstRow.originY
            var maxX = Int64.min
            var maxY = Int64.min
            for row in rows {
                let (width, widthOverflow) = row.siteCount.multipliedReportingOverflow(by: row.siteWidth)
                let (endX, xOverflow) = row.originX.addingReportingOverflow(width)
                let (endY, yOverflow) = row.originY.addingReportingOverflow(row.height)
                guard row.siteCount > 0, row.siteWidth > 0, row.height > 0, !widthOverflow, !xOverflow, !yOverflow else {
                    throw PhysicalDesignTechnologyError.invalid("ROW geometry requires positive and representable extents.")
                }
                minX = min(minX, row.originX)
                minY = min(minY, row.originY)
                maxX = max(maxX, endX)
                maxY = max(maxY, endY)
            }
            let (width, widthOverflow) = maxX.subtractingReportingOverflow(minX)
            let (height, heightOverflow) = maxY.subtractingReportingOverflow(minY)
            guard !widthOverflow, !heightOverflow else { throw PhysicalDesignTechnologyError.invalid("Combined ROW bounds exceed the coordinate range.") }
            return PhysicalDesignSnapshot.Rect(x: minX, y: minY, width: width, height: height)
        }

        private mutating func parseRoutes(in item: [PhysicalDesignDEFToken], netID: String) -> [PhysicalDesignSnapshot.Route] {
            // FIXME(INCOMPLETE_IMPLEMENTATION): Process-bound DEF route/via semantic preservation is owned by B6. Native API/CLI must reject existing routed clauses until that standard import is exact.
            if processFactory != nil, let token = item.first(where: { ["ROUTED", "FIXED", "COVER", "NEW"].contains($0.text.uppercased()) }) {
                addDiagnostic(severity: .error, code: "def_process_routes_unsupported", message: "Exact process-bound DEF route/via interchange is not complete.",
                    token: token, section: "NETS", entity: netID, suggestedActions: ["provide_supported_exact_route_interchange"])
                return []
            }
            var result: [PhysicalDesignSnapshot.Route] = []
            var routeOrdinal = 0
            for position in item.indices where item[position].text.uppercased() == "ROUTED" {
                guard position + 1 < item.count, let layer = parseLayer(item[position + 1]) else {
                    addDiagnostic(
                        severity: .error,
                        code: "def_route_layer_invalid",
                        message: "ROUTED record for net \(netID) does not contain a layer identifier.",
                        token: item[position],
                        section: "NETS",
                        entity: netID,
                        suggestedActions: ["provide_a_routed_layer_identifier"]
                    )
                    continue
                }
                var points: [(Int64, Int64)] = []
                var scan = position + 2
                while scan + 3 < item.count, item[scan].text != "+" {
                    if let first = Int64(item[scan + 1].text), let second = Int64(item[scan + 2].text), item[scan].text == "(", item[scan + 3].text == ")" {
                        points.append((first, second))
                        scan += 4
                    } else {
                        scan += 1
                    }
                }
                guard points.count >= 2 else {
                    addDiagnostic(
                        severity: .error,
                        code: "def_route_geometry_invalid",
                        message: "ROUTED record for net \(netID) needs at least two coordinate pairs.",
                        token: item[position],
                        section: "NETS",
                        entity: netID,
                        suggestedActions: ["provide_two_or_more_route_points"]
                    )
                    continue
                }
                var segments: [PhysicalDesignSnapshot.RouteSegment] = []
                for segmentIndex in 0..<(points.count - 1) {
                    let start = points[segmentIndex]
                    let end = points[segmentIndex + 1]
                    segments.append(PhysicalDesignSnapshot.RouteSegment(
                        id: "route_\(netID)_\(routeOrdinal)_\(segmentIndex)",
                        layer: layer,
                        x1: start.0,
                        y1: start.1,
                        x2: end.0,
                        y2: end.1
                    ))
                }
                result.append(PhysicalDesignSnapshot.Route(id: "route_\(netID)_\(routeOrdinal)", netID: netID, segments: segments))
                routeOrdinal += 1
            }
            return result
        }

        private mutating func rectangle(from statement: [PhysicalDesignDEFToken], section: String) -> PhysicalDesignSnapshot.Rect? {
            var points: [(Int64, Int64)] = []
            var position = 0
            while position + 3 < statement.count, points.count < 2 {
                if let x = Int64(statement[position + 1].text), let y = Int64(statement[position + 2].text), statement[position].text == "(", statement[position + 3].text == ")" {
                    points.append((x, y))
                    position += 4
                } else {
                    position += 1
                }
            }
            guard points.count == 2 else { return nil }
            let x = min(points[0].0, points[1].0)
            let y = min(points[0].1, points[1].1)
            let maxX = max(points[0].0, points[1].0)
            let maxY = max(points[0].1, points[1].1)
            guard maxX > x, maxY > y else {
                addDiagnostic(
                    severity: .error,
                    code: "def_rectangle_non_positive",
                    message: "\(section) rectangle must have positive width and height.",
                    token: statement.first ?? tokens[max(0, index - 1)],
                    section: section,
                    suggestedActions: ["provide_distinct_rectangle_corners"]
                )
                return nil
            }
            let (width, widthOverflow) = maxX.subtractingReportingOverflow(x)
            let (height, heightOverflow) = maxY.subtractingReportingOverflow(y)
            guard !widthOverflow, !heightOverflow else {
                addDiagnostic(severity: .error, code: "def_rectangle_overflow", message: "\(section) rectangle exceeds the coordinate range.",
                    token: statement.first ?? tokens[max(0, index - 1)], section: section, suggestedActions: ["repair_representable_rectangle_extents"])
                return nil
            }
            return PhysicalDesignSnapshot.Rect(x: x, y: y, width: width, height: height)
        }

        private mutating func coordinatePair(in statement: [PhysicalDesignDEFToken], start: Int, section: String) -> (Int64, Int64)? {
            guard start + 3 < statement.count, statement[start].text == "(" else { return nil }
            guard let x = integer(statement[start + 1], section: section), let y = integer(statement[start + 2], section: section), statement[start + 3].text == ")" else {
                addDiagnostic(
                    severity: .error,
                    code: "def_coordinate_pair_invalid",
                    message: "Coordinate pair in \(section) is malformed.",
                    token: statement[start],
                    section: section,
                    suggestedActions: ["provide_integer_coordinate_pairs"]
                )
                return nil
            }
            return (x, y)
        }

        private mutating func integer(_ token: PhysicalDesignDEFToken, section: String) -> Int64? {
            guard let value = Int64(token.text) else {
                addDiagnostic(
                    severity: .error,
                    code: "def_integer_invalid",
                    message: "Expected an integer in \(section), found \(token.text).",
                    token: token,
                    section: section,
                    suggestedActions: ["use_integer_database_unit_coordinates"]
                )
                return nil
            }
            return value
        }

        private func parseLayer(_ token: PhysicalDesignDEFToken) -> Int? {
            if processFactory != nil {
                let definitions = processGeometry?.layers.values.filter { $0.name == token.text || $0.aliases.contains(token.text) } ?? []
                guard definitions.count == 1 else { return nil }
                return definitions.first?.number
            }
            let value = token.text.uppercased().replacingOccurrences(of: "M", with: "")
            return Int(value)
        }

        private mutating func addDiagnostic(
            severity: DiagnosticSeverity,
            code: String,
            message: String,
            token: PhysicalDesignDEFToken,
            section: String,
            entity: String? = nil,
            suggestedActions: [String]
        ) {
            diagnostics.append(PhysicalDesignDEFDiagnostic(
                severity: severity,
                code: code,
                message: message,
                line: token.line,
                section: section,
                entity: entity,
                suggestedActions: suggestedActions
            ))
        }

        private mutating func addDiagnostic(
            severity: DiagnosticSeverity,
            code: String,
            message: String,
            line: Int,
            section: String,
            entity: String? = nil,
            suggestedActions: [String]
        ) {
            diagnostics.append(PhysicalDesignDEFDiagnostic(
                severity: severity,
                code: code,
                message: message,
                line: line,
                section: section,
                entity: entity,
                suggestedActions: suggestedActions
            ))
        }
    }
}
