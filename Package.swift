// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sill",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Sill",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Sill",
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/Blocklists")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
