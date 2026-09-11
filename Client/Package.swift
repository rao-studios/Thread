// swift-tools-version: 5.10.0

import PackageDescription

let package = Package(
    name: "DatabaseDemo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DatabaseDemo",
            path: "Sources",
            resources: [.process("Resources")]
        )
    ]
)
