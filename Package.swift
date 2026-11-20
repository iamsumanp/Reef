// swift-tools-version: 5.10
//
// Lets Reef be built without Xcode (Command Line Tools only): `./build.sh`.
// The Xcode project remains the source of truth for releases; this manifest
// just compiles the same sources and pins the same dependency versions.

import PackageDescription

let package = Package(
    name: "Reef",
    platforms: [.macOS("14.6")],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "Reef",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Reef",
            exclude: [
                "Assets.xcassets",
                "Preview Content",
                "reef_placeholder.icon",
                "Info.plist",
                "Reef.entitlements",
            ]
        )
    ]
)
