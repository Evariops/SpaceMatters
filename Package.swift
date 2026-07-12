// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceMatters",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SpaceMatters", targets: ["SpaceMatters"])
    ],
    dependencies: [
        // Auto-update (SPEC-12). Binary XCFramework; ≥ 2.9 for native markdown
        // release notes. SwiftPM copies the framework next to dev/test binaries
        // (@loader_path); the .app bundle embeds it under Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "SpaceMatters",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SpaceMatters",
            swiftSettings: [
                // Pragmatic: the scanner uses a hand-rolled thread pool with
                // manual synchronization, which fights Swift 6 strict concurrency.
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ],
            linkerSettings: [
                // Where Packaging/bundle.sh embeds Sparkle.framework in the .app.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
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
