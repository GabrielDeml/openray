// swift-tools-version: 6.2

import PackageDescription

// docs/DESIGN.md §3.4: Swift 6 language mode, and plain `async` functions run on their caller's actor.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "OpenRayCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenRayCore", targets: ["OpenRayCore"])
    ],
    // docs/DESIGN.md §5.2 lists every allowed dependency and the exact version it is pinned to.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")
    ],
    targets: [
        .target(
            name: "OpenRayCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            // The string catalog with Core's user-visible text (docs/DESIGN.md §5.5).
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OpenRayCoreTests",
            dependencies: ["OpenRayCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
