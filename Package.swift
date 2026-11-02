// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarinaUI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "MarinaUI",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/MarinaUI",
            resources: [
                .process("Resources"),
            ]
        )
    ]
)
