// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EeroDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EeroCore", targets: ["EeroCore"]),
        .executable(name: "EeroDesktop", targets: ["EeroDesktop"]),
    ],
    targets: [
        // Platform-neutral API client, request contracts and validation. Builds on macOS and Linux.
        .target(name: "EeroCore", path: "Sources/EeroCore"),
        // Native macOS SwiftUI application. Non-macOS builds compile to a stub entry point.
        .executableTarget(
            name: "EeroDesktop",
            dependencies: ["EeroCore"],
            path: "Sources/EeroDesktop",
            resources: [.copy("Resources/products"), .copy("Resources/app-icon.png")]
        ),
        .testTarget(name: "EeroCoreTests", dependencies: ["EeroCore"], path: "Tests/EeroCoreTests"),
    ]
)
