// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IndexCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IndexCore", targets: ["IndexCore"]),
    ],
    targets: [
        .target(name: "IndexCore"),
        .testTarget(name: "IndexCoreTests", dependencies: ["IndexCore"]),
    ]
)
