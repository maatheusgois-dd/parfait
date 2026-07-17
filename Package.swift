// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nutola",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "Nutola",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Nutola",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NutolaTests",
            dependencies: ["Nutola"],
            path: "Tests/NutolaTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
