// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SpaceBar", targets: ["SpaceBar"]),
              .executable(name: "spacebar-cli", targets: ["SpaceBarCLI"])],
    targets: [
        .target(name: "SpaceBarCore"),
        .executableTarget(name: "SpaceBar", dependencies: ["SpaceBarCore"]),
        .executableTarget(name: "SpaceBarCLI", dependencies: ["SpaceBarCore"]),
        .executableTarget(name: "SpaceBarChecks", dependencies: ["SpaceBarCore"], path: "Tests/SpaceBarCoreTests"),
    ]
)
