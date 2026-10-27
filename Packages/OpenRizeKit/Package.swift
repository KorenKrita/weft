// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenRizeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenRizeKit", targets: ["OpenRizeKit"]),
    ],
    targets: [
        .target(name: "OpenRizeKit"),
        .testTarget(name: "OpenRizeKitTests", dependencies: ["OpenRizeKit"]),
    ]
)
