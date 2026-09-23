// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CarbShared",
    platforms: [
        // Matches what the app and widget targets actually require. macOS is
        // only the host platform for `swift test`, so it stays where it is.
        .iOS("26.0"),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CarbShared", targets: ["CarbShared"]),
    ],
    targets: [
        .target(
            name: "CarbShared",
            path: "Sources/CarbShared"
        ),
        .testTarget(
            name: "CarbSharedTests",
            dependencies: ["CarbShared"],
            path: "Tests/CarbSharedTests"
        ),
    ]
)
