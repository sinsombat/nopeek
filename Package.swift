// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoPeek",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "PWCore", targets: ["PWCore"]),
        .executable(name: "NoPeekApp", targets: ["NoPeekApp"]),
    ],
    targets: [
        .target(name: "PWCore"),
        .executableTarget(name: "NoPeekApp", dependencies: ["PWCore"]),
        // The log-line fixtures travel with the tests so `swift test` can read
        // them through `Bundle.module` from any working directory.
        .testTarget(
            name: "PWCoreTests",
            dependencies: ["PWCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
