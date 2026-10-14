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
        ),
        .executable(
            name: "que-sign",
            targets: ["QueSign"]
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
        ),
        .executableTarget(
            name: "QueSign",
            dependencies: ["QueCore"]
        )
    ]
)
