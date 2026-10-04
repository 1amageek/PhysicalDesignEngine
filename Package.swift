// swift-tools-version: 6.3
import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    exact: "26.812.0"
)

let logicDesignDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/LogicDesign.git",
    exact: "26.812.0"
)

let pdkKitDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/PDKKit.git",
    revision: "c2b143f566b1e92308dfdebb2764067a141da75a"
)

let swiftMaskDataDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/swift-mask-data.git",
    revision: "41f72fe3ca7a35b1cda53f59e780b029faf1b718"
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
        .library(name: "PhysicalDesignEngine", targets: ["PhysicalDesignEngine"]),
        .library(name: "PhysicalDesignCLISupport", targets: ["PhysicalDesignCLISupport"]),
        .executable(name: "physical-design", targets: ["PhysicalDesignCLI"]),
    ],
    dependencies: [
        circuiteFoundationDependency,
        logicDesignDependency,
        pdkKitDependency,
        swiftMaskDataDependency,
        .package(url: "https://github.com/1amageek/CoreSpice.git", revision: "305d0933018f8a987c73c5186f53740ca315a516"),
        .package(url: "https://github.com/1amageek/PEXEngine.git", revision: "3610774dd3c0675e7f5d9289d5efd69fd60cfb43"),
        .package(url: "https://github.com/1amageek/TimingEngine.git", revision: "122f474f1e5ee8c012537f44dc61ce588ddc9bb1"),
        .package(url: "https://github.com/1amageek/semiconductor-layout.git", revision: "dde1fb35d5d7db7f7da7746d29235fc8c21105b5"),
    ],
    targets: [
        .target(
            name: "PhysicalDesignCore",
            dependencies: [
                .product(name: "TimingCore", package: "TimingEngine"),
                .product(name: "PEXNative", package: "PEXEngine"),
                .product(name: "PEXCore", package: "PEXEngine"),
                .product(name: "CoreSpice", package: "CoreSpice"),
                .product(name: "LayoutCore", package: "semiconductor-layout"),
                .product(name: "LayoutTech", package: "semiconductor-layout"),
                .product(name: "LayoutVerify", package: "semiconductor-layout"),
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit"),
                .product(name: "LEF", package: "swift-mask-data"),
                .product(name: "DEF", package: "swift-mask-data"),
                .product(name: "MaskGeometry", package: "swift-mask-data")
            ],
            exclude: ["DESIGN.md", "TechnologyConstraints/DESIGN.md", "ProcessInputs/DESIGN.md", "MasterGeometry/DESIGN.md", "ProcessGeometry/DESIGN.md", "LegalPlacement/DESIGN.md", "RoutingGeometry/DESIGN.md", "ClockTreeSynthesis/DESIGN.md", "StandardLayoutExport/DESIGN.md"]
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
