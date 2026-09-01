// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacChannel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacChannelCore", targets: ["MacChannelCore"]),
        .executable(name: "MacChannelApp", targets: ["MacChannelApp"]),
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
                .define("MACCHANNEL_LEGACY_MESH", .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "MacChannelAppKit",
            dependencies: [
                "MacChannelCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "App",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "MacChannelApp",
            dependencies: ["MacChannelCore", "MacChannelAppKit"]
        ),
        .testTarget(
            name: "MacChannelCoreTests",
            dependencies: ["MacChannelCore", "MacChannelAppKit"]
        ),
        .testTarget(
            name: "MacChannelIntegrationTests",
            dependencies: [
                "MacChannelCore",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Tests/Integration"
        ),
    ]
)
