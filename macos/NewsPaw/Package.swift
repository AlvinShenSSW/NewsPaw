// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NewsPaw",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NewsPaw", targets: ["NewsPaw"])],
    targets: [
        .executableTarget(name: "NewsPaw", resources: [.process("Resources")]),
        .testTarget(name: "NewsPawTests", dependencies: ["NewsPaw"]),
    ]
)
