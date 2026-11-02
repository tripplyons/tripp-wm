// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tripp-wm",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(
            url: "https://github.com/dduan/TOMLDecoder.git",
            exact: "0.4.5"
        ),
    ],
    targets: [
        // Window layout, commands, and configuration without AppKit, so tests
        // can drive the window manager through a fake window backend.
        .target(
            name: "TrippWMCore",
            dependencies: [
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/TrippWMCore"
        ),
        .executableTarget(
            name: "tripp-wm",
            dependencies: ["TrippWMCore"],
            path: "Sources/tripp-wm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "tripp-wmctl",
            dependencies: ["TrippWMCore"],
            path: "Sources/tripp-wmctl"
        ),
        .testTarget(
            name: "TrippWMCoreTests",
            dependencies: ["TrippWMCore"],
            path: "Tests"
        ),
    ]
)
