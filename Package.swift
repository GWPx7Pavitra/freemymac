// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FreeMyMac",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "FreeMyMac", targets: ["FreeMyMac"]),
    ],
    targets: [
        .target(name: "FreeMyMacCore"),
        .executableTarget(name: "FreeMyMac", dependencies: ["FreeMyMacCore"]),
        .testTarget(name: "FreeMyMacCoreTests", dependencies: ["FreeMyMacCore"]),
    ]
)
