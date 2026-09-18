// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeleportConnectNative",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "TshdProto", targets: ["TshdProto"]),
        .library(name: "TshdKit", targets: ["TshdKit"]),
        .executable(name: "tshd-smoketest", targets: ["tshd-smoketest"]),
        .executable(name: "TeleportConnectNative", targets: ["TeleportConnectNative"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.0"),
        // Pinned below 1.15.0: from there on, SwiftTerm's package processes a .metal shader
        // file unconditionally, which needs Xcode's Metal compiler — not present with only
        // Command Line Tools installed (this machine's setup). 1.10.0 predates that.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.0"),
    ],
    targets: [
        .target(
            name: "TshdProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ]
        ),
        .target(
            name: "TshdKit",
            dependencies: [
                "TshdProto",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
            ]
        ),
        .executableTarget(
            name: "tshd-smoketest",
            dependencies: ["TshdKit"]
        ),
        .executableTarget(
            name: "TeleportConnectNative",
            dependencies: ["TshdKit", "TshdProto", "SwiftTerm"],
            resources: [.copy("Resources/ResourceIcons")]
        ),
    ]
)
