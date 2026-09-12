// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacChannel",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MacChannelCore", targets: ["MacChannelCore"]),
        .executable(name: "MacChannelApp", targets: ["MacChannelApp"]),
        .executable(name: "DropMeshAppStore", targets: ["DropMeshAppStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "150.0.0"),
    ],
    targets: [
        .target(
            name: "MacChannelCore",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            swiftSettings: [
                .define("MACCHANNEL_LEGACY_MESH", .when(platforms: [.macOS], configuration: .debug)),
            ]
        ),
        .target(
            name: "MacChannelAppKit",
            dependencies: ["MacChannelCore"],
            path: "App",
            resources: [.copy("Resources")]
        ),
        .target(
            name: "MacChannelDirectDistribution",
            dependencies: [
                "MacChannelCore",
                "MacChannelAppKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .target(
            name: "DropMeshAppStoreDistribution",
            dependencies: ["MacChannelCore", "MacChannelAppKit"]
        ),
        .executableTarget(
            name: "MacChannelApp",
            dependencies: ["MacChannelAppKit", "MacChannelDirectDistribution"]
        ),
        .executableTarget(
            name: "DropMeshAppStore",
            dependencies: ["MacChannelAppKit", "DropMeshAppStoreDistribution"]
        ),
        .testTarget(
            name: "MacChannelCoreTests",
            dependencies: [
                "MacChannelCore",
                "MacChannelAppKit",
                "MacChannelDirectDistribution",
                "DropMeshAppStoreDistribution",
            ]
        ),
        .testTarget(
            name: "MacChannelIntegrationTests",
            dependencies: [
                "MacChannelCore",
                "MacChannelAppKit",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Tests/Integration"
        ),
    ]
)
