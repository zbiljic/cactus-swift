// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "cactus-swift",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Cactus", targets: ["Cactus"])],
    targets: [
        .target(name: "Cactus"),
        .testTarget(name: "CactusTests", dependencies: ["Cactus"]),
    ]
)
