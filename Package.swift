// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacChannel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacChannelCore", targets: ["MacChannelCore"]),
        .executable(name: "MacChannelApp", targets: ["MacChannelApp"]),
    ],
    targets: [
        .target(name: "MacChannelCore"),
        .executableTarget(
            name: "MacChannelApp",
            dependencies: ["MacChannelCore"]
        ),
        .testTarget(
            name: "MacChannelCoreTests",
            dependencies: ["MacChannelCore"]
        ),
    ]
)
