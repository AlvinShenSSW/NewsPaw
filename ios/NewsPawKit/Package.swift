// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NewsPawKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NewsPawKit", targets: ["NewsPawKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.3"),
    ],
    targets: [
        .target(
            name: "NewsPawKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            exclude: [
                "Reading/Resources/LICENSE",
                "Reading/Resources/README.md",
            ],
            resources: [
                .copy("Reading/Resources/Readability.js"),
            ]
        ),
        .testTarget(
            name: "NewsPawKitTests",
            dependencies: [
                "NewsPawKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
