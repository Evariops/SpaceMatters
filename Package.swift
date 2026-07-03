// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDirStats",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacDirStats", targets: ["MacDirStats"])
    ],
    targets: [
        .executableTarget(
            name: "MacDirStats",
            path: "Sources/MacDirStats",
            swiftSettings: [
                // Pragmatic: the scanner uses a hand-rolled thread pool with
                // manual synchronization, which fights Swift 6 strict concurrency.
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "MacDirStatsTests",
            dependencies: ["MacDirStats"],
            path: "Tests/MacDirStatsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
