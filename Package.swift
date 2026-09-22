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
    .package(url: "https://github.com/rao-studios/Conduit.git", branch: "main"),
    // A SIBLING PATH, NOT THE URL — verified, not inherited lore. Switching this to
    // `.package(url:branch:)` fails resolution outright:
    //
    //     error: package 'frigate' is required using a revision-based requirement
    //            and it depends on local package 'visionax', which is not supported
    //
    // Frigate declares `.package(path: "../VisionAX")` inside `#if !os(Linux)`, and
    // Thread is macOS-only, so that edge is always live here. Neither repo carries
    // tags, so `branch:` is the only requirement form available — and a revision-based
    // requirement is precisely what SwiftPM refuses for a package with a local
    // dependency. Even with a tag it would not work: `../VisionAX` resolved from
    // inside `.build/checkouts/Frigate` points at a sibling that was never cloned.
    //
    // To take Frigate by URL, Frigate must first stop depending on VisionAX by path.
    // Until then: every other consumer already takes Frigate this way, and on the
    // Linux box setup-cuda-ubuntu.sh puts the sibling in place.
    .package(path: "../Frigate")
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
    // mlx-swift-lm 3.x takes the downloader and tokenizer as parameters; FrigateBridge
    // carries Frigate's concrete HubDownloader / HubTokenizerLoader.
    .product(name: "FrigateBridge", package: "Frigate"),
    .product(name: "Conduit", package: "Conduit"),
    // The shared ~/.rao contract: stack secret, /health proof, provider keys.
    .product(name: "RaoStack", package: "Conduit"),
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
        .product(name: "RaoStack", package: "Conduit"),
        .product(name: "HummingbirdTesting", package: "hummingbird"),
      ],
      path: "Tests/thread-tests"
    )
  ]
)
