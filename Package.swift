// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Wirely",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WirelyCore"),
        .target(name: "WirelyHelperKit", dependencies: ["WirelyCore"]),
        .target(name: "WirelyApp", dependencies: ["WirelyCore"]),
        .executableTarget(name: "Wirely", dependencies: ["WirelyApp"]),
        .executableTarget(name: "wirely-helper", dependencies: ["WirelyHelperKit", "WirelyCore"]),
        .testTarget(name: "WirelyCoreTests", dependencies: ["WirelyCore"]),
        .testTarget(name: "WirelyAppTests", dependencies: ["WirelyApp", "WirelyCore"]),
        .testTarget(name: "WirelyHelperKitTests", dependencies: ["WirelyHelperKit", "WirelyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
