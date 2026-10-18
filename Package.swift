// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "T3CodeKitty",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "KittyCore",
            path: "Sources/KittyCore"
        ),
        .executableTarget(
            name: "T3CodeKitty",
            dependencies: ["KittyCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "KittyCoreTests",
            dependencies: ["KittyCore"],
            path: "Tests/KittyCoreTests"
        ),
    ]
)
