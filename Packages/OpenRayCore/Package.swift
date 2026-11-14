// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenRayCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenRayCore", targets: ["OpenRayCore"])
    ],
    targets: [
        .target(name: "OpenRayCore"),
        .testTarget(name: "OpenRayCoreTests", dependencies: ["OpenRayCore"]),
    ]
)
