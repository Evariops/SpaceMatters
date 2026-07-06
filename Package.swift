// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceMatters",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SpaceMatters", targets: ["SpaceMatters"])
    ],
    targets: [
        .executableTarget(
            name: "SpaceMatters",
            path: "Sources/SpaceMatters",
            swiftSettings: [
                // Pragmatic: the scanner uses a hand-rolled thread pool with
                // manual synchronization, which fights Swift 6 strict concurrency.
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "SpaceMattersTests",
            dependencies: ["SpaceMatters"],
            path: "Tests/SpaceMattersTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
