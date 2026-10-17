// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MagpieLite",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MagpieLite", targets: ["MagpieLite"]),
    ],
    targets: [
        .target(
            name: "MagpieLiteCore",
            path: "Sources/MagpieLiteCore"
        ),
        .executableTarget(
            name: "MagpieLite",
            dependencies: ["MagpieLiteCore"],
            path: "Sources/MagpieLite"
        ),
        .testTarget(
            name: "MagpieLiteCoreTests",
            dependencies: ["MagpieLiteCore"],
            path: "Tests/MagpieLiteCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
