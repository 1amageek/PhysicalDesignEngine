import Foundation
import Testing
import LEF
@testable import PhysicalDesignCore

@Suite("Canonical master dimensions")
struct MasterGeometryTests {
    @Test("missing and partial DEF dimensions never become fabricated cells", arguments: ["", "+ PROPERTY XCI_CELL_WIDTH 2000"])
    func missingDimensions(extensionText: String) throws {
        let result = PhysicalDesignDEFParser().parse(def(extensionText))
        #expect(result.snapshot == nil)
        #expect(result.diagnostics.contains { $0.code == "def_cell_geometry_unresolved" && $0.entity == "U1" })
    }

    @Test("LEF master dimensions are authoritative and exact", arguments: [
        "valid", "missing-master", "duplicate", "missing-size", "off-grid", "nonfinite",
        "negative", "mismatch", "duplicate-dimension", "missing-units", "explicit-smoke", "unsupported-orientation"
    ])
    func masterResolution(scenario: String) throws {
        var master = LEFMacroDef(name: "INV_X1", width: 1.234, height: 2.345)
        if scenario == "missing-master" { master.name = "ANOTHER" }
        if scenario == "missing-size" { master.height = nil }
        if scenario == "off-grid" { master.width = 1.2345 }
        if scenario == "nonfinite" { master.width = .infinity }
        if scenario == "negative" { master.width = -1 }
        var masters = [master]
        if scenario == "duplicate" { masters.append(master) }
        var extensionText = ""
        if scenario == "mismatch" { extensionText = "+ PROPERTY XCI_CELL_WIDTH 1000 + PROPERTY XCI_CELL_HEIGHT 2345" }
        if scenario == "duplicate-dimension" { extensionText = "+ PROPERTY XCI_CELL_WIDTH 1000 + PROPERTY XCI_CELL_WIDTH 1234" }
        if scenario == "explicit-smoke" {
            masters = []
            extensionText = "+ PROPERTY XCI_CELL_WIDTH 1234 + PROPERTY XCI_CELL_HEIGHT 2345"
        }
        var data = def(extensionText)
        if scenario == "missing-units" {
            data = Data(try #require(String(data: data, encoding: .utf8)).replacingOccurrences(of: "UNITS DISTANCE MICRONS 1000 ;", with: "").utf8)
        }
        if scenario == "unsupported-orientation" {
            data = Data(try #require(String(data: data, encoding: .utf8)).replacingOccurrences(of: ") N", with: ") FN").utf8)
        }
        let result = PhysicalDesignDEFParser().parse(data, cellMasters: masters)
        if scenario == "valid" || scenario == "explicit-smoke" {
            let cell = try #require(result.snapshot?.cells.first)
            #expect(cell.width == 1234)
            #expect(cell.height == 2345)
            #expect(cell.x == 2000 && cell.y == 3000)
            #expect(!result.diagnostics.contains { $0.code == "def_cell_geometry_defaulted" })
        } else {
            #expect(result.snapshot == nil)
            #expect(result.diagnostics.contains { $0.severity == .error && $0.entity == "U1" })
        }
    }

    private func def(_ extensionText: String = "") -> Data {
        Data("""
        VERSION 5.8 ;
        DESIGN master_top ;
        UNITS DISTANCE MICRONS 1000 ;
        DIEAREA ( 0 0 ) ( 20000 20000 ) ;
        COMPONENTS 1 ;
        - U1 INV_X1 + PLACED ( 2000 3000 ) N \(extensionText) ;
        END COMPONENTS
        END DESIGN
        """.utf8)
    }
}
