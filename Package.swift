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
    exact: "26.812.0"
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
    ],
    targets: [
        .target(
            name: "PhysicalDesignCore",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
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
