// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonicSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SonicSwitch", targets: ["SonicSwitch"])],
    targets: [
        .target(name: "VPNCore"),
        .executableTarget(name: "SonicSwitch", dependencies: ["VPNCore"]),
        .testTarget(name: "VPNCoreTests", dependencies: ["VPNCore"]),
        .testTarget(name: "SonicSwitchTests", dependencies: ["SonicSwitch", "VPNCore"])
    ]
)
