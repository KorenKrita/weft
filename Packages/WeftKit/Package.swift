// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WeftKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WeftKit", targets: ["WeftKit"]),
    ],
    targets: [
        .target(name: "WeftKit"),
        .testTarget(name: "WeftKitTests", dependencies: ["WeftKit"]),
    ]
)
