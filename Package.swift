// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Que",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "QueCore",
            targets: ["QueCore"]
        ),
        .executable(
            name: "Que",
            targets: ["QueApp"]
        ),
        .executable(
            name: "que-tests",
            targets: ["QueTests"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "QueCore",
            dependencies: []
        ),
        .executableTarget(
            name: "QueApp",
            dependencies: ["QueCore"]
        ),
        .executableTarget(
            name: "QueTests",
            dependencies: ["QueCore"]
        )
    ]
)
