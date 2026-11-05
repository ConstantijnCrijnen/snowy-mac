// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snowy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Snowy", targets: ["Snowy"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "SnowCore"),
        .executableTarget(
            name: "Snowy",
            dependencies: ["SnowCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Shaders/Snow.metal")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SnowCoreTests", dependencies: ["SnowCore"])
    ]
)
