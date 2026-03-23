// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIUsageTracker",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(
            name: "AIUsageTracker",
            targets: ["AIUsageTracker"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "AIUsageTracker",
            path: "Sources",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AIUsageTrackerTests",
            dependencies: ["AIUsageTracker"],
            path: "Tests"
        ),
    ]
)
