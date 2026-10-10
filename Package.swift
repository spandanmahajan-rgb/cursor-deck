// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CursorDeck",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CursorDeckCore",
            targets: ["CursorDeckCore"]
        ),
        .executable(
            name: "CursorDeckApp",
            targets: ["CursorDeckApp"]
        ),
        .executable(
            name: "cursor-deck-tests",
            targets: ["CursorDeckTests"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CursorDeckCore",
            dependencies: []
        ),
        .executableTarget(
            name: "CursorDeckApp",
            dependencies: ["CursorDeckCore"]
        ),
        .executableTarget(
            name: "CursorDeckTests",
            dependencies: ["CursorDeckCore"]
        )
    ]
)
