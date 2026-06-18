// swift-tools-version: 6.0

import PackageDescription

// Applied to every Swift target: opt fully into the Swift 6 language mode so the
// whole package is checked under complete data-race safety on every platform.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "FileRepo",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(
            name: "FileRepo",
            targets: ["FileRepo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", branch: "main"),
        .package(url: "https://github.com/sveamarcus/HaByLo", branch: "main"),
    ],
    targets: [
        .target(
            name: "FileRepo",
            dependencies: [
                "HaByLo",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings),
        .testTarget(
            name: "FileRepoTests",
            dependencies: ["FileRepo"],
            swiftSettings: swiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
