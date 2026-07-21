// swift-tools-version: 6.3
import PackageDescription
import Foundation

let workspaceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let isLSIWorkspace = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("docs/workspace-packages.json").path
)

let circuiteFoundationDependency: Package.Dependency = isLSIWorkspace && FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("CircuiteFoundation/Package.swift").path
)
    ? .package(path: "../CircuiteFoundation")
    : .package(url: "https://github.com/1amageek/CircuiteFoundation.git", revision: "7abcac83517935c9b9f7553d7016d62cffde259d")

let logicDesignDependency: Package.Dependency = isLSIWorkspace && FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("LogicDesign/Package.swift").path
)
    ? .package(path: "../LogicDesign")
    : .package(url: "https://github.com/1amageek/LogicDesign.git", revision: "b9aa25b0b78e6168befa25df3bfe8309bd020a6d")

let pdkKitDependency: Package.Dependency = isLSIWorkspace && FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("PDKKit/Package.swift").path
)
    ? .package(path: "../PDKKit")
    : .package(url: "https://github.com/1amageek/PDKKit.git", revision: "b62c5ad7e5819a24977038c2133856caed52f481")

let signoffToolSupportDependency: Package.Dependency = isLSIWorkspace && FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("SignoffToolSupport/Package.swift").path
)
    ? .package(path: "../SignoffToolSupport")
    : .package(
        url: "https://github.com/1amageek/SignoffToolSupport.git",
        revision: "6bf675eecb27e3bd3440c5ce8a85c85c510fc3cb"
    )

let package = Package(
    name: "PhysicalDesignEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhysicalDesignCore", targets: ["PhysicalDesignCore"]),
        .library(name: "FloorplanEngine", targets: ["FloorplanEngine"]),
        .library(name: "PlacementEngine", targets: ["PlacementEngine"]),
        .library(name: "CTSEngine", targets: ["CTSEngine"]),
        .library(name: "RoutingEngine", targets: ["RoutingEngine"]),
        .library(name: "PhysicalECO", targets: ["PhysicalECO"]),
        .library(name: "PhysicalDFM", targets: ["PhysicalDFM"]),
        .library(name: "OpenROADPhysicalDesign", targets: ["OpenROADPhysicalDesign"]),
        .library(name: "PhysicalDesignEngine", targets: ["PhysicalDesignEngine"]),
        .library(name: "PhysicalDesignCLISupport", targets: ["PhysicalDesignCLISupport"]),
        .executable(name: "physical-design", targets: ["PhysicalDesignCLI"]),
    ],
    dependencies: [
        circuiteFoundationDependency,
        logicDesignDependency,
        pdkKitDependency,
        signoffToolSupportDependency,
    ],
    targets: [
        .target(
            name: "PhysicalDesignCore",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit")
            ]
        ),
        .target(
            name: "FloorplanEngine",
            dependencies: ["PhysicalDesignCore"]
        ),
        .target(
            name: "PlacementEngine",
            dependencies: ["PhysicalDesignCore"]
        ),
        .target(
            name: "CTSEngine",
            dependencies: ["PhysicalDesignCore"]
        ),
        .target(
            name: "RoutingEngine",
            dependencies: ["PhysicalDesignCore"]
        ),
        .target(
            name: "PhysicalECO",
            dependencies: ["PhysicalDesignCore"]
        ),
        .target(
            name: "PhysicalDFM",
            dependencies: ["PhysicalDesignCore"]
        ),
        .target(
            name: "OpenROADPhysicalDesign",
            dependencies: [
                "PhysicalDesignCore",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ]
        ),
        .target(
            name: "PhysicalDesignEngine",
            dependencies: ["PhysicalDesignCore", "FloorplanEngine", "PlacementEngine", "CTSEngine", "RoutingEngine", "PhysicalECO", "PhysicalDFM", "OpenROADPhysicalDesign"]
        ),
        .target(
            name: "PhysicalDesignCLISupport",
            dependencies: ["PhysicalDesignCore", "PhysicalDesignEngine"]
        ),
        .executableTarget(
            name: "PhysicalDesignCLI",
            dependencies: ["PhysicalDesignCLISupport"]
        ),
        .testTarget(
            name: "PhysicalDesignEngineTests",
            dependencies: [
                "PhysicalDesignCore",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                "FloorplanEngine",
                "PlacementEngine",
                "CTSEngine",
                "RoutingEngine",
                "PhysicalECO",
                "PhysicalDFM",
                "OpenROADPhysicalDesign",
                "PhysicalDesignEngine",
                "PhysicalDesignCLISupport",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport")
            ],
            resources: [.copy("../../Fixtures")]
        ),
    ]
)
