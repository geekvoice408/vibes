// swift-tools-version:5.9
import PackageDescription

// Built with SwiftPM and the Command Line Tools only — see CLAUDE.md.
// SwiftTerm is pinned to 1.11.2: 1.12+ ships a Metal shader that needs
// Xcode's `metal` compiler, which the Command Line Tools do not have.
let package = Package(
    name: "ServerLife",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
    ],
    targets: [
        .systemLibrary(name: "CShim", path: "Sources/CShim"),
        .executableTarget(
            name: "ServerLife",
            dependencies: [
                "CShim",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/ServerLife",
            // Each owner documents its API in a README beside the code.
            exclude: [
                "Data/README.md",
                "Connections/README.md",
                "Teleport/Service/README.md",
                "Teleport/UI/README.md",
                "Files/Service/README.md",
                "Files/Explorer/README.md",
                "Devices/Service/README.md",
                "Devices/UI/README.md",
                "Sessions/README.md",
                "Sidebar/README.md",
                "Hosts/README.md",
                "Fleet/README.md",
                "NetTools/README.md",
                "City/README.md",
                "Misc/README.md",
                "Automation/README.md",
            ],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "ServerLifeTests",
            dependencies: ["ServerLife"],
            path: "Tests/ServerLifeTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
