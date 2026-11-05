// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenFence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScreenFence", targets: ["ScreenFence"]),
        .executable(name: "ScreenFenceProbe", targets: ["ScreenFenceProbe"]),
        .library(name: "ScreenFenceCore", targets: ["ScreenFenceCore"])
    ],
    targets: [
        .target(name: "ScreenFenceCore"),
        .executableTarget(name: "ScreenFence", dependencies: ["ScreenFenceCore"]),
        .executableTarget(name: "ScreenFenceProbe", dependencies: ["ScreenFenceCore"]),
        .testTarget(name: "ScreenFenceCoreTests", dependencies: ["ScreenFenceCore"])
    ],
    swiftLanguageModes: [.v5]
)
