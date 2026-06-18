// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PCKBottle",
    platforms: [.macOS(.v10_13)],
    products: [
        .executable(name: "PCKBottle", targets: ["PCKBottleApp"]),
    ],
    targets: [
        .executableTarget(
            name: "PCKBottleApp",
            path: "Sources/PCKBottleApp"
        ),
    ]
)
