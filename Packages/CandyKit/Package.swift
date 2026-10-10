// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CandyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "T3Protocol", targets: ["T3Protocol"]),
        .library(name: "T3Client", targets: ["T3Client"]),
        .library(name: "T3Store", targets: ["T3Store"]),
        .library(name: "Features", targets: ["Features"]),
    ],
    targets: [
        .target(name: "DesignSystem", exclude: ["Icons/LICENSE-lucide.txt"], resources: [.copy("Resources/surface-grain.rgba")]),
        // Wire and domain types from docs/protocol.md. No I/O.
        .target(name: "T3Protocol"),
        // Transport: HTTP auth, WebSocket RPC, reconnect supervisor, Keychain.
        .target(name: "T3Client", dependencies: ["T3Protocol"]),
        // Normalized state and reducers fed by T3Client streams.
        .target(name: "T3Store", dependencies: ["T3Protocol"]),
        // Screens built from DesignSystem components and fed by T3Store (sidebar, timeline, composer...).
        .target(name: "Features", dependencies: ["DesignSystem", "T3Store", "T3Protocol"], resources: [.copy("Resources/candy-town.gray")]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
        .testTarget(name: "T3ProtocolTests", dependencies: ["T3Protocol"]),
        .testTarget(name: "T3ClientTests", dependencies: ["T3Client"]),
        .testTarget(name: "T3StoreTests", dependencies: ["T3Store"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "DesignSystem", "T3Store", "T3Protocol"]),
    ]
)
