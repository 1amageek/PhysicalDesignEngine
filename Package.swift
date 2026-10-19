// swift-tools-version: 6.4
import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    revision: "5f132c58209123433e0e479e1ea61096e46061ba"
)

let logicDesignDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/LogicDesign.git",
    revision: "5e1d3eec838a0add91c617413682d186a5182335"
)

let pdkKitDependency: Package.Dependency = .package(url: "https://github.com/1amageek/PDKKit.git",
    revision: "f59dfd1dbdd20545ddf97e6a0ab9a956ad7ca809"
)

let swiftMaskDataDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/swift-mask-data.git",
    revision: "67410f834bdfa8a098c2ec0bfe3675210f658277"
)

let package = Package(
    name: "PhysicalDesignEngine",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PhysicalDesignLogicHandoff", targets: ["PhysicalDesignLogicHandoff"]),
        .library(name: "PhysicalDesignCore", targets: ["PhysicalDesignCore"]),
        .library(name: "FloorplanEngine", targets: ["FloorplanEngine"]),
        .library(name: "PlacementEngine", targets: ["PlacementEngine"]),
        .library(name: "CTSEngine", targets: ["CTSEngine"]),
        .library(name: "RoutingEngine", targets: ["RoutingEngine"]),
        .library(name: "PhysicalECO", targets: ["PhysicalECO"]),
        .library(name: "PhysicalDFM", targets: ["PhysicalDFM"]),
        .library(name: "PhysicalDesignEngine", targets: ["PhysicalDesignEngine"]),
        .library(name: "PhysicalDesignCLISupport", targets: ["PhysicalDesignCLISupport"]),
        .executable(name: "physical-design", targets: ["PhysicalDesignCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/LogicEngine.git", revision: "a6dead5545439c8b5fb2dd9860bf498d8f62be56"),
        circuiteFoundationDependency,
        logicDesignDependency,
        pdkKitDependency,
        swiftMaskDataDependency,
        .package(url: "https://github.com/1amageek/CoreSpice.git", revision: "cfcadac5aeff5d95681d2d91c0bf3e75bd35f169"),
        .package(url: "https://github.com/1amageek/PEXEngine.git", revision: "8b8ead61d08ba9a6f43c191b1897f7bac09c530c"),
        .package(url: "https://github.com/1amageek/DRCEngine.git", revision: "05724746320b56c41fc40c1bfe3366015ad54d65"),
        .package(url: "https://github.com/1amageek/TimingEngine.git", revision: "be979a9e3095e811f5d7cc4d5f74668142d9c052"),
        .package(url: "https://github.com/1amageek/semiconductor-layout.git", revision: "8c66b7bd6b44cab884b75ded9788a4ec548a1919"),
    ],
    targets: [
        .target(name: "PhysicalDesignLogicHandoff", dependencies: ["PhysicalDesignCore",
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
            .product(name: "TimingCore", package: "TimingEngine"),
            .product(name: "STAEngine", package: "TimingEngine"),
            .product(name: "LogicProof", package: "LogicEngine"),
            .product(name: "LogicSimulation", package: "LogicEngine"),
            .product(name: "LogicEngineRuntime", package: "LogicEngine"),
            .product(name: "LogicIR", package: "LogicDesign"),
            .product(name: "LogicKernelCore", package: "LogicDesign"),
                .product(name: "LogicDesignSerialization", package: "LogicDesign"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation")], exclude: ["DESIGN.md", "CheckedCandidatePersistence/DESIGN.md"]),
        .testTarget(name: "PhysicalLogicHandoffTests", dependencies: ["PhysicalDesignLogicHandoff", "PhysicalDesignCore",
            .product(name: "PEXNative", package: "PEXEngine"),
            .product(name: "PEXParsers", package: "PEXEngine"),
            .product(name: "TimingCore", package: "TimingEngine"),
            .product(name: "STAEngine", package: "TimingEngine"),
            .product(name: "DEF", package: "swift-mask-data"),
            .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            .product(name: "PDKCore", package: "PDKKit"),
            .product(name: "PEXCore", package: "PEXEngine"),
            .product(name: "LogicProof", package: "LogicEngine"),
            .product(name: "LogicSimulation", package: "LogicEngine"),
            .product(name: "LogicEngineCore", package: "LogicEngine"),
            .product(name: "LogicEngineRuntime", package: "LogicEngine"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
            .product(name: "LogicIR", package: "LogicDesign")], resources: [.copy("Fixtures")]),
        .target(
            name: "PhysicalDesignCore",
            dependencies: [
                .product(name: "TimingCore", package: "TimingEngine"),
                .product(name: "STAEngine", package: "TimingEngine"),
                .product(name: "PEXNative", package: "PEXEngine"),
                .product(name: "PEXCore", package: "PEXEngine"),
                .product(name: "PEXParsers", package: "PEXEngine"),
                .product(name: "DRCNative", package: "DRCEngine"),
                .product(name: "DRCCore", package: "DRCEngine"),
                .product(name: "CoreSpice", package: "CoreSpice"),
                .product(name: "LayoutCore", package: "semiconductor-layout"),
                .product(name: "LayoutTech", package: "semiconductor-layout"),
                .product(name: "LayoutVerify", package: "semiconductor-layout"),
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "LogicDesignSerialization", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit"),
                .product(name: "LEF", package: "swift-mask-data"),
                .product(name: "DEF", package: "swift-mask-data"),
                .product(name: "MaskGeometry", package: "swift-mask-data")
            ],
            exclude: ["DESIGN.md", "TechnologyConstraints/DESIGN.md", "ProcessInputs/DESIGN.md", "MasterGeometry/DESIGN.md", "ProcessGeometry/DESIGN.md", "LegalPlacement/DESIGN.md", "RoutingGeometry/DESIGN.md", "RoutingSourceAdoption/DESIGN.md", "ClockTreeSynthesis/DESIGN.md", "StandardLayoutExport/DESIGN.md", "RepairMeasurement/DESIGN.md", "DEFImport/DESIGN.md"]
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
            name: "PhysicalDesignEngine",
            dependencies: ["PhysicalDesignCore", "FloorplanEngine", "PlacementEngine", "CTSEngine", "RoutingEngine", "PhysicalECO", "PhysicalDFM"]
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
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                "FloorplanEngine",
                "PlacementEngine",
                "CTSEngine",
                "RoutingEngine",
                "PhysicalECO",
                "PhysicalDFM",
                "PhysicalDesignEngine",
                "PhysicalDesignCLISupport"
            ],
            resources: [.copy("../../Fixtures")]
        ),
    ]
)
