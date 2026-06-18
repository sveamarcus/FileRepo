// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "FileRepo",
    platforms: [.iOS(.v13), .macOS(.v13), .watchOS(.v6), .tvOS(.v13)],
    products: [
        .library(
            name: "FileRepo",
            targets: ["FileRepo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "FileRepo",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings),
        .testTarget(
            name: "FileRepoTests",
            dependencies: ["FileRepo"],
            swiftSettings: swiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
