// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LarkMini",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.56.0")
    ],
    targets: [
        .executableTarget(
            name: "LarkMini",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"),
                           .product(name: "Sentry", package: "sentry-cocoa")],
            path: "Sources/LarkMini"
        ),
        .testTarget(name: "LarkMiniTests", dependencies: ["LarkMini"])
    ]
)
