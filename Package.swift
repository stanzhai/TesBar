// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TesBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TesBar", resources: [
            .process("Resources"),
        ]),
        .testTarget(name: "TesBarTests", dependencies: ["TesBar"]),
    ]
)
