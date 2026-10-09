// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CandyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "T3Protocol", targets: ["T3Protocol"]),
    ],
    targets: [
        .target(name: "DesignSystem", exclude: ["Icons/LICENSE-lucide.txt"]),
        .target(name: "T3Protocol"),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ]
)
