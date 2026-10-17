// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Argus",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Argus", targets: ["Argus"]),
    ],
    targets: [
        .target(
            name: "ArgusCore",
            path: "Sources/ArgusCore"
        ),
        .executableTarget(
            name: "Argus",
            dependencies: ["ArgusCore"],
            path: "Sources/Argus"
        ),
        .testTarget(
            name: "ArgusCoreTests",
            dependencies: ["ArgusCore"],
            path: "Tests/ArgusCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
