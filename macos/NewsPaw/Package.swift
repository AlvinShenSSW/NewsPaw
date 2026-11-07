// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NewsPaw",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NewsPaw", targets: ["NewsPaw"]),
        .executable(name: "NewsPawResident", targets: ["NewsPawResident"]),
    ],
    targets: [
        .executableTarget(name: "NewsPaw", resources: [.process("Resources")]),
        .executableTarget(name: "NewsPawResident"),
        .testTarget(name: "NewsPawTests", dependencies: ["NewsPaw"]),
    ]
)
