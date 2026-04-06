// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ClaudeStand",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(
            name: "ClaudeStand",
            targets: ["ClaudeStand"]
        ),
    ],
    dependencies: [
        .package(path: "../swift-bun"),
    ],
    targets: [
        .target(
            name: "ClaudeStand",
            dependencies: [
                .product(name: "BunRuntime", package: "swift-bun"),
            ]
        ),
        .testTarget(
            name: "ClaudeStandTests",
            dependencies: ["ClaudeStand"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
