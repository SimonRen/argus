// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Argus",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Argus", targets: ["Argus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(
            name: "ArgusCore",
            path: "Sources/ArgusCore"
        ),
        .executableTarget(
            name: "Argus",
            dependencies: ["ArgusCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Argus",
            // Sparkle.framework ships in Contents/Frameworks of the bundle `make build` assembles.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "ArgusCoreTests",
            dependencies: ["ArgusCore"],
            path: "Tests/ArgusCoreTests"
        ),
        .testTarget(
            name: "ArgusTests",
            dependencies: ["Argus"],
            path: "Tests/ArgusTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
