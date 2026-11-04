// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snowy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Snowy", targets: ["Snowy"])],
    targets: [
        .target(name: "SnowCore"),
        .executableTarget(
            name: "Snowy",
            dependencies: ["SnowCore"],
            resources: [.copy("Shaders/Snow.metal")]
        ),
        .testTarget(name: "SnowCoreTests", dependencies: ["SnowCore"])
    ]
)
