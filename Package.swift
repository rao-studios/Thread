// swift-tools-version: 6.0

import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMajor(from: "1.3.0")),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
    .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    // A SIBLING PATH, NOT THE URL. Frigate carries a path dependency of its own
    // (../VisionAX, macOS only), and SwiftPM refuses a package required by URL that
    // depends on a local package. Every other consumer already takes Frigate this way;
    // on the Linux box, setup-cuda-ubuntu.sh puts the sibling in place.
    .package(path: "../Frigate"),
    // .package(url: "https://github.com/rao-studios/Frigate.git", branch: "main"),
    .package(path: "../Conduit")
    // .package(url: "https://github.com/rao-studios/Conduit.git", branch: "main")
]

var targetDependencies: [Target.Dependency] = [
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
    .product(name: "Hummingbird", package: "hummingbird"),
    .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "GRPCCore", package: "grpc-swift"),
    .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
    .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
    .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    .product(name: "MLX", package: "Frigate"),
    .product(name: "MLXLMCommon", package: "Frigate"),
    .product(name: "MLXLLM", package: "Frigate"),
    .product(name: "mlx_embeddings", package: "Frigate"),
    .product(name: "MLXAccelerate", package: "Frigate"),
    .product(name: "Frigate", package: "Frigate"),
    .product(name: "Conduit", package: "Conduit"),
]

let supportedPlatforms: [SupportedPlatform] = [.macOS(.v15)]

let package = Package(
  name: "thread",
  platforms: supportedPlatforms,
  dependencies: packageDependencies,
  targets: [
    .executableTarget(
      name: "thread",
      dependencies: targetDependencies,
      path: "Sources"
    ),
    .testTarget(
      name: "thread-tests",
      dependencies: [
        "thread",
        .product(name: "Conduit", package: "Conduit"),
        .product(name: "HummingbirdTesting", package: "hummingbird"),
      ],
      path: "Tests/thread-tests"
    )
  ]
)
