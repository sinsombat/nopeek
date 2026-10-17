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
        .testTarget(name: "PWCoreTests", dependencies: ["PWCore"]),
    ]
)
