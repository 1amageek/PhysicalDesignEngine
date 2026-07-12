// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PhysicalDesignEngine",
    platforms: [.macOS(.v14)],
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
        .package(path: "../XcircuitePackage"),
        .package(path: "../LogicDesign"),
        .package(path: "../TimingEngine"),
        .package(path: "../PDKKit"),
    ],
    targets: [
        .target(
            name: "PhysicalDesignCore",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), .product(name: "LogicIR", package: "LogicDesign"), .product(name: "TimingCore", package: "TimingEngine"), .product(name: "PDKCore", package: "PDKKit")]
        ),
        .target(
            name: "FloorplanEngine",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "PhysicalDesignCore"]
        ),
        .target(
            name: "PlacementEngine",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "PhysicalDesignCore"]
        ),
        .target(
            name: "CTSEngine",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "PhysicalDesignCore"]
        ),
        .target(
            name: "RoutingEngine",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "PhysicalDesignCore"]
        ),
        .target(
            name: "PhysicalECO",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "PhysicalDesignCore"]
        ),
        .target(
            name: "PhysicalDFM",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "PhysicalDesignCore"]
        ),
        .target(
            name: "PhysicalDesignEngine",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "PhysicalDesignCore", "FloorplanEngine", "PlacementEngine", "CTSEngine", "RoutingEngine", "PhysicalECO", "PhysicalDFM"]
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
            dependencies: ["PhysicalDesignCore", "FloorplanEngine", "PlacementEngine", "CTSEngine", "RoutingEngine", "PhysicalECO", "PhysicalDFM", "PhysicalDesignEngine", "PhysicalDesignCLISupport"]
        ),
    ]
)
