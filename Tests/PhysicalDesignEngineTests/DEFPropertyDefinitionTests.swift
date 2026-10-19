import Foundation
import Testing
import LEF
@testable import PhysicalDesignCore

@Suite("Reserved DEF dimension declarations", .timeLimit(.minutes(2)))
struct DEFPropertyDefinitionTests {
    @Test("actual OpenROAD declarations preserve complete canonical geometry")
    func genuineOpenROAD() throws {
        let data: Data
        if let path = ProcessInfo.processInfo.environment["LSI_PHYSICAL_DEF_GRAMMAR_SOURCE"] {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(data == Data(genuine.utf8))
        } else { data = Data(genuine.utf8) }
        #expect(data.count == 399)
        let result = PhysicalDesignDEFParser().parse(data)
        #expect(!result.diagnostics.contains { $0.severity == .error || $0.code.contains("unsupported") }, "\(result.diagnostics)")
        let snapshot = try #require(result.snapshot)
        let cell = try #require(snapshot.cells.first)
        #expect(snapshot.topCell == "top")
        #expect(cell.id == "U1" && cell.master == "NAND2")
        #expect(cell.width == 1000 && cell.height == 2000)
        #expect(cell.x == 1000 && cell.y == 2000)
        #expect(cell.placed && cell.orientation == .n)
    }

    @Test("unsupported declarations refuse at their owning grammar", arguments: [
        "unknown", "owner", "type", "default", "range", "duplicate", "repeat", "missing-semicolon", "changed-end", "missing-end"
    ])
    func declarationRefusal(_ scenario: String) throws {
        let width = "COMPONENT XCI_CELL_WIDTH INTEGER ;"
        var text = genuine
        let code: String
        switch scenario {
        case "unknown": text = text.replacingOccurrences(of: width, with: "COMPONENT UNOWNED INTEGER ;"); code = "def_property_definition_unknown"
        case "owner": text = text.replacingOccurrences(of: width, with: "DESIGN XCI_CELL_WIDTH INTEGER ;"); code = "def_property_definition_changed"
        case "type": text = text.replacingOccurrences(of: width, with: "COMPONENT XCI_CELL_WIDTH REAL ;"); code = "def_property_definition_changed"
        case "default": text = text.replacingOccurrences(of: width, with: "COMPONENT XCI_CELL_WIDTH INTEGER 1000 ;"); code = "def_property_definition_unsupported"
        case "range": text = text.replacingOccurrences(of: width, with: "COMPONENT XCI_CELL_WIDTH INTEGER RANGE 0 2000 ;"); code = "def_property_definition_unsupported"
        case "duplicate": text = text.replacingOccurrences(of: width, with: width + "\n" + width); code = "def_property_definition_duplicate"
        case "repeat": text = text.replacingOccurrences(of: "END PROPERTYDEFINITIONS", with: "END PROPERTYDEFINITIONS\nPROPERTYDEFINITIONS\n" + width + "\nEND PROPERTYDEFINITIONS"); code = "def_property_definitions_repeated"
        case "missing-semicolon": text = text.replacingOccurrences(of: "COMPONENT XCI_CELL_HEIGHT INTEGER ;", with: "COMPONENT XCI_CELL_HEIGHT INTEGER"); code = "def_property_definition_terminator_missing"
        case "changed-end": text = text.replacingOccurrences(of: "END PROPERTYDEFINITIONS", with: "END COMPONENTS"); code = "def_section_end_mismatch"
        default: let end = try #require(text.range(of: "COMPONENT XCI_CELL_HEIGHT INTEGER ;")); text = String(text[..<end.upperBound]); code = "def_property_definitions_end_missing"
        }
        let result = PhysicalDesignDEFParser().parse(Data(text.utf8))
        #expect(result.snapshot == nil)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.code == code && $0.section == "PROPERTYDEFINITIONS" }, "\(result.diagnostics)")
    }

    @Test("declarations do not replace geometry authority", arguments: ["missing-values", "master-mismatch", "single-declaration", "no-declarations"])
    func geometryAuthority(_ scenario: String) throws {
        var text = genuine
        var masters: [LEFMacroDef] = []
        let code: String?
        switch scenario {
        case "missing-values":
            text = text.replacingOccurrences(of: "+ PROPERTY XCI_CELL_WIDTH 1000 XCI_CELL_HEIGHT 2000", with: "")
            code = "def_cell_geometry_unresolved"
        case "master-mismatch":
            masters = [LEFMacroDef(name: "NAND2", width: 2, height: 2)]
            code = "def_cell_geometry_unresolved"
        case "single-declaration":
            text = text.replacingOccurrences(of: "COMPONENT XCI_CELL_HEIGHT INTEGER ;\n", with: "")
            code = nil
        default:
            let header = try #require(text.range(of: "PROPERTYDEFINITIONS\n"))
            let end = try #require(text.range(of: "END PROPERTYDEFINITIONS\n"))
            text.removeSubrange(header.lowerBound..<end.upperBound)
            code = nil
        }
        let result = PhysicalDesignDEFParser().parse(Data(text.utf8), cellMasters: masters)
        if let code {
            #expect(result.snapshot == nil)
            #expect(result.diagnostics.contains { $0.severity == .error && $0.code == code }, "\(result.diagnostics)")
        } else {
            #expect(result.diagnostics.isEmpty)
            let cell = try #require(result.snapshot?.cells.first)
            #expect(cell.width == 1000 && cell.height == 2000)
        }
    }

    private var genuine: String {
        """
        VERSION 5.8 ;
        DIVIDERCHAR "/" ;
        BUSBITCHARS "[]" ;
        DESIGN top ;
        UNITS DISTANCE MICRONS 1000 ;
        PROPERTYDEFINITIONS
        COMPONENT XCI_CELL_WIDTH INTEGER ;
        COMPONENT XCI_CELL_HEIGHT INTEGER ;
        END PROPERTYDEFINITIONS
        DIEAREA ( 0 0 ) ( 100000 100000 ) ;
        COMPONENTS 1 ;
            - U1 NAND2 + PLACED ( 1000 2000 ) N + PROPERTY XCI_CELL_WIDTH 1000 XCI_CELL_HEIGHT 2000  ;
        END COMPONENTS
        NETS 0 ;
        END NETS
        END DESIGN
        """ + "\n"
    }
}
