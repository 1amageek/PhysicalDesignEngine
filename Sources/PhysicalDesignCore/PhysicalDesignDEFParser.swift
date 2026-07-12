import Foundation
import XcircuitePackage

public struct PhysicalDesignDEFParser: Sendable {
    public static let parserID = "physical-design-def-parser"
    public static let parserVersion = "1.0.0"

    public init() {}

    public func parse(_ data: Data) -> PhysicalDesignDEFParseResult {
        guard let source = String(data: data, encoding: .utf8) else {
            return PhysicalDesignDEFParseResult(
                snapshot: nil,
                diagnostics: [PhysicalDesignDEFDiagnostic(
                    severity: .error,
                    code: "def_invalid_utf8",
                    message: "DEF input is not valid UTF-8.",
                    line: 1,
                    section: "header",
                    suggestedActions: ["provide_utf8_encoded_def"]
                )]
            )
        }
        var state = State()
        state.parse(source)
        return state.result()
    }

    private struct State {
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
                        severity: .warning,
                        code: "def_unsupported_section",
                        message: "DEF statement or section \(token.text) is outside the supported interchange subset.",
                        token: token,
                        section: "header",
                        suggestedActions: ["convert_the_input_to_the_supported_def_subset"]
                    )
                    skipUnsupportedStatement(named: token.text)
                }
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
            let inferredCore = coreInferredFromRows()
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
                implementationState: implementationState()
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
            guard let version = statement.first else { return }
            if version.text != "5.8" {
                addDiagnostic(
                    severity: .warning,
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
            unitsPerMicron = Int(value)
        }

        private mutating func parseDieArea(_ token: PhysicalDesignDEFToken) {
            let statement = readStatementTokens()
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
            var x: Int64 = 0
            var y: Int64 = 0
            var width: Int64 = 1_000
            var height: Int64 = 10_000
            var placed = false
            var locked = false
            var hasPlacement = false
            let uppercased = item.map { $0.text.uppercased() }
            for position in item.indices {
                if uppercased[position] == "PLACED" || uppercased[position] == "FIXED" || uppercased[position] == "COVER" {
                    placed = true
                    locked = uppercased[position] == "FIXED"
                    if position + 1 < item.count, let point = coordinatePair(in: item, start: position + 1, section: "COMPONENTS") {
                        x = point.0
                        y = point.1
                        hasPlacement = true
                    }
                }
                if uppercased[position] == "SIZE", position + 3 < item.count,
                   let parsedWidth = integer(item[position + 1], section: "COMPONENTS"),
                   uppercased[position + 2] == "BY",
                   let parsedHeight = integer(item[position + 3], section: "COMPONENTS") {
                    width = parsedWidth
                    height = parsedHeight
                }
                if uppercased[position] == "XCI_CELL_WIDTH", position + 1 < item.count,
                   let parsedWidth = integer(item[position + 1], section: "COMPONENTS") {
                    width = parsedWidth
                }
                if uppercased[position] == "XCI_CELL_HEIGHT", position + 1 < item.count,
                   let parsedHeight = integer(item[position + 1], section: "COMPONENTS") {
                    height = parsedHeight
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
            let hasGeometryExtension = item.contains { token in
                let value = token.text.uppercased()
                return value == "SIZE" || value == "XCI_CELL_WIDTH" || value == "XCI_CELL_HEIGHT"
            }
            if !hasGeometryExtension {
                addDiagnostic(
                    severity: .warning,
                    code: "def_cell_geometry_defaulted",
                    message: "Component \(id) does not carry a SIZE extension; canonical cell geometry defaults to 1000 by 10000 database units.",
                    token: item[0],
                    section: "COMPONENTS",
                    entity: id,
                    suggestedActions: ["provide_lef_geometry_or_a_supported_size_extension"]
                )
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
                locked: locked
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
                parsePin(item)
                actualCount += 1
            }
            finishSection(named: "PINS", expectedCount: expectedCount, actualCount: actualCount, token: token)
        }

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
            while position + 3 < item.count {
                if item[position].text == "(", item[position + 3].text == ")",
                   Int64(item[position + 1].text) == nil, Int64(item[position + 2].text) == nil {
                    let cellName = item[position + 1].text
                    let pinName = item[position + 2].text
                    let pinID = ensurePin(cellID: cellName.uppercased() == "PIN" ? nil : cellName, name: pinName, token: item[position + 1])
                    if !pinIDs.contains(pinID) {
                        pinIDs.append(pinID)
                    }
                    setNetID(netID, forPinID: pinID)
                    position += 4
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
                isClock: netID.lowercased().contains("clk"),
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

        private func coreInferredFromRows() -> PhysicalDesignSnapshot.Rect? {
            guard let firstRow = rows.first else { return nil }
            var minX = firstRow.originX
            var minY = firstRow.originY
            var maxX = firstRow.originX + firstRow.siteCount * firstRow.siteWidth
            var maxY = firstRow.originY + firstRow.height
            for row in rows.dropFirst() {
                minX = min(minX, row.originX)
                minY = min(minY, row.originY)
                maxX = max(maxX, row.originX + row.siteCount * row.siteWidth)
                maxY = max(maxY, row.originY + row.height)
            }
            guard maxX > minX, maxY > minY else { return nil }
            return PhysicalDesignSnapshot.Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        private mutating func parseRoutes(in item: [PhysicalDesignDEFToken], netID: String) -> [PhysicalDesignSnapshot.Route] {
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
                while scan + 3 < item.count {
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
            return PhysicalDesignSnapshot.Rect(x: x, y: y, width: maxX - x, height: maxY - y)
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
            let value = token.text.uppercased().replacingOccurrences(of: "M", with: "")
            return Int(value)
        }

        private mutating func addDiagnostic(
            severity: XcircuiteEngineDiagnosticSeverity,
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
            severity: XcircuiteEngineDiagnosticSeverity,
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
