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
    revision: "397056f97812a1b7da7e79993b3e0d1fa6cb6476"
)

let swiftMaskDataDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/swift-mask-data.git",
    revision: "d62cc0d52bbe9fa66957d5e2a954765cc885cd4d"
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
        .package(url: "https://github.com/1amageek/CoreSpice.git", revision: "8fbcee58575b37a01795e11110731cfc16566520"),
        .package(url: "https://github.com/1amageek/PEXEngine.git", revision: "fe1895d30958127d6c59ee5d55567159f4cd40c6"),
        .package(url: "https://github.com/1amageek/TimingEngine.git", revision: "9dad85f41c7f8e3ad596ef80ac2904cf20d6852d"),
        .package(url: "https://github.com/1amageek/semiconductor-layout.git", revision: "688ffac1839a0705e907e8a5ed665f32e591b057"),
    ],
    targets: [
        .target(
            name: "PhysicalDesignCore",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit"),
                .product(name: "LEF", package: "swift-mask-data"),
                .product(name: "DEF", package: "swift-mask-data"),
                .product(name: "MaskGeometry", package: "swift-mask-data")
            ],
            exclude: ["DESIGN.md", "TechnologyConstraints/DESIGN.md", "ProcessInputs/DESIGN.md", "MasterGeometry/DESIGN.md", "ProcessGeometry/DESIGN.md", "LegalPlacement/DESIGN.md", "RoutingGeometry/DESIGN.md"]
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
