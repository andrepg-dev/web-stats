// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "web-stats",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "web-stats", targets: ["WebStats"])
    ],
    targets: [
        .executableTarget(
            name: "WebStats"
        )
    ]
)
