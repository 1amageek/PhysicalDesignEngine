// swift-tools-version: 6.3
import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    revision: "ae88104c556f5802819713ed741f5b2fffffc2d9"
)

let logicDesignDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/LogicDesign.git",
    revision: "d13cebf1454e124a352f87186a22a70ef47d99a5"
)

let pdkKitDependency: Package.Dependency = .package(url: "https://github.com/1amageek/PDKKit.git",
    revision: "82376ee435c753af524c2c58e904d98665c8c7cb"
)

let swiftMaskDataDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/swift-mask-data.git",
    revision: "b505ffd739b8fd4b8df9695423e9cdd4469b4f92"
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
        .package(url: "https://github.com/1amageek/CoreSpice.git", revision: "fce8ca02194eabc63b4455f80070c1b8847a3377"),
        .package(url: "https://github.com/1amageek/PEXEngine.git", revision: "6fdd2e1a6a8183e5e1196455bc8741063111206e"),
        .package(url: "https://github.com/1amageek/TimingEngine.git", revision: "98a4f62c7186c955521e09fcf424b6ef8d217555"),
        .package(url: "https://github.com/1amageek/semiconductor-layout.git", revision: "17278fb7340e98a7af5a960766083c0e0c39f69b"),
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
