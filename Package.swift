// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TesBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TesBar", path: "Sources/TesBar"),
        .testTarget(name: "TesBarTests", dependencies: ["TesBar"], path: "Tests/TesBarTests"),
    ]
)
