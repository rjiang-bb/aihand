// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AiHand",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "AiHand",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/TinyHand",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
