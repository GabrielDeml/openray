// swift-tools-version: 6.2

import PackageDescription

// docs/DESIGN.md §3.4: Swift 6 language mode, and plain `async` functions run on their caller's actor.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "OpenRayCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenRayCore", targets: ["OpenRayCore"])
    ],
    targets: [
        .target(name: "OpenRayCore", swiftSettings: swiftSettings),
        .testTarget(
            name: "OpenRayCoreTests",
            dependencies: ["OpenRayCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
