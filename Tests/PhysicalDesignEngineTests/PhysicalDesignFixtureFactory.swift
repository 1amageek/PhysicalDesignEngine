import Foundation
import CircuiteFoundation
import LogicIR
import PDKCore
@testable import PhysicalDesignCore

enum PhysicalDesignFixtureFactory {
    static let designDigest = String(repeating: "b", count: 64)
    static let pdkDigest = String(repeating: "c", count: 64)
    static let configuration = PhysicalDesignConfiguration(
        dieWidth: 100_000,
        dieHeight: 100_000,
        coreMargin: 10_000,
        rowHeight: 1_000,
        siteWidth: 100,
        placementSpacing: 200,
        preferredRoutingLayers: [2, 3, 4, 5],
        maximumRoutingLayer: 6,
        targetUtilization: 0.70,
        powerNetNames: ["VDD", "VSS"],
        maximumAntennaRatio: 300,
        fillWindowSize: 20_000,
        fillSpacing: 2_000,
        ecoAction: .resizeCell,
        deterministicSeed: 0
    )

    static func artifact(
        path: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        role: ArtifactRole = .input,
        digest: String = String(repeating: "a", count: 64),
        byteCount: UInt64 = 1
    ) -> ArtifactReference {
        do {
            let locator = ArtifactLocator(
                location: try ArtifactLocation(workspaceRelativePath: path),
                role: role,
                kind: kind,
                format: format
            )
            let contentDigest = try ContentDigest(algorithm: .sha256, hexadecimalValue: digest)
            return ArtifactReference(locator: locator, digest: contentDigest, byteCount: byteCount)
        } catch {
            fatalError("Invalid physical-design fixture artifact: \(error)")
        }
    }

    static func request(
        stage: PhysicalDesignStage,
        snapshot: PhysicalDesignSnapshot? = nil,
        configuration: PhysicalDesignConfiguration = PhysicalDesignFixtureFactory.configuration
    ) -> PhysicalDesignRequest {
        PhysicalDesignRequest(
            runID: "test-\(stage.rawValue)",
            inputs: [],
            design: LogicDesignReference(
                artifact: artifact(path: "inputs/design.json", kind: .netlist, format: .json),
                topDesignName: "fixture_top",
                designDigest: designDigest
            ),
            constraints: artifact(path: "inputs/constraints.sdc", kind: .constraint, format: .sdc),
            requestedModeIDs: ["func"],
            pdk: PDKReference(
                manifest: artifact(path: "inputs/pdk.json", kind: .technology, format: .json),
                processID: "fixture-130nm",
                version: "1",
                digest: pdkDigest
            ),
            stage: stage,
            configuration: configuration,
            initialSnapshot: snapshot
        )
    }

    static func snapshot(
        includeFloorplan: Bool = true,
        includePlacement: Bool = true,
        includeRoutes: Bool = true,
        includeVias: Bool = true,
        includeHotspot: Bool = true
    ) -> PhysicalDesignSnapshot {
        let die = PhysicalDesignSnapshot.Rect(x: 0, y: 0, width: 100_000, height: 100_000)
        let core = PhysicalDesignSnapshot.Rect(x: 10_000, y: 10_000, width: 80_000, height: 80_000)
        let row = PhysicalDesignSnapshot.Row(id: "row_0", originX: 10_000, originY: 10_000, siteWidth: 100, height: 1_000, siteCount: 800)
        let upperRow = PhysicalDesignSnapshot.Row(id: "row_1", originX: 10_000, originY: 11_000, siteWidth: 100, height: 1_000, siteCount: 800)
        let cells = [
            PhysicalDesignSnapshot.Cell(id: "U1", master: "NAND2_X1", x: 20_000, y: 10_000, height: 1_000, placed: includePlacement),
            PhysicalDesignSnapshot.Cell(id: "U2", master: "BUF_X1", x: 30_000, y: 11_000, height: 1_000, placed: includePlacement)
        ]
        let pins = [
            PhysicalDesignSnapshot.Pin(id: "CLK_SRC", cellID: "U1", name: "CK", x: 20_500, y: 10_500, netID: "CLK", direction: "output"),
            PhysicalDesignSnapshot.Pin(id: "CLK_SINK", cellID: "U2", name: "CK", x: 30_500, y: 11_500, netID: "CLK", direction: "input"),
            PhysicalDesignSnapshot.Pin(id: "A", cellID: "U1", name: "A", x: 20_200, y: 10_200, netID: "DATA", direction: "output"),
            PhysicalDesignSnapshot.Pin(id: "Y", cellID: "U2", name: "Y", x: 30_200, y: 11_200, netID: "DATA", direction: "input")
        ]
        let nets = [
            PhysicalDesignSnapshot.Net(id: "CLK", pinIDs: ["CLK_SRC", "CLK_SINK"], isClock: true),
            PhysicalDesignSnapshot.Net(id: "DATA", pinIDs: ["A", "Y"], antennaRatio: 500, maximumAntennaRatio: 300)
        ]
        let routes: [PhysicalDesignSnapshot.Route] = includeRoutes ? [
            PhysicalDesignSnapshot.Route(
                id: "route_DATA",
                netID: "DATA",
                segments: [PhysicalDesignSnapshot.RouteSegment(id: "data_segment", layer: 2, x1: 20_500, y1: 10_500, x2: 30_500, y2: 10_500)]
            )
        ] : []
        let vias: [PhysicalDesignSnapshot.Via] = includeVias ? [
            PhysicalDesignSnapshot.Via(id: "via_DATA_0", netID: "DATA", x: 25_000, y: 10_500, lowerLayer: 2, upperLayer: 3)
        ] : []
        let hotspots: [PhysicalDesignSnapshot.Hotspot] = includeHotspot ? [
            PhysicalDesignSnapshot.Hotspot(id: "hotspot_0", geometry: PhysicalDesignSnapshot.Rect(x: 40_000, y: 40_000, width: 1_000, height: 1_000), severity: "warning")
        ] : []
        return PhysicalDesignSnapshot(
            topCell: "fixture_top",
            die: includeFloorplan ? die : nil,
            core: includeFloorplan ? core : nil,
            rows: includeFloorplan ? [row, upperRow] : [],
            cells: cells,
            pins: pins,
            nets: nets,
            routes: routes,
            vias: vias,
            hotspots: hotspots,
            metadata: ["fixture": "native"]
        )
    }
}
