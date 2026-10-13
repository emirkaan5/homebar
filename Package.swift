// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HomeBar", targets: ["HomeBarApp"]),
        .executable(name: "homebar-cli", targets: ["HomeBarCLI"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Platform", dependencies: ["Core"]),
        .target(name: "SmartRentProvider", dependencies: ["Core"]),
        .target(name: "HueProvider", dependencies: ["Core"]),
        .target(name: "UI", dependencies: ["Core"]),
        .executableTarget(name: "HomeBarApp", dependencies: ["Core", "UI", "SmartRentProvider", "HueProvider", "Platform"]),
        .executableTarget(name: "HomeBarCLI", dependencies: ["Core", "SmartRentProvider", "HueProvider", "Platform"]),
        .testTarget(
            name: "HomeBarTests",
            dependencies: ["Core", "SmartRentProvider", "HueProvider"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
