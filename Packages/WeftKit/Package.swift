// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WeftKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WeftKit", targets: ["WeftKit"]),
    ],
    targets: [
        .target(name: "WeftKit", resources: [.process("Localizable.xcstrings")]),
        .testTarget(name: "WeftKitTests", dependencies: ["WeftKit"]),
    ]
)
