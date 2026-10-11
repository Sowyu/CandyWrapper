// swift-tools-version: 6.0
import PackageDescription

// Release builds optimize for size: the shipped bundle stays well under the spec's 25 MB for benchmarks 2 to 8%
// slower (docs/perf/README.md, "Milestone 7 wrap-up"). Packages ignore the app project's settings.
let sizeOptimized: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

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
    dependencies: [
        // SwiftTerm v1.19.0, vendored (Packages/SwiftTerm/README.md says why).
        .package(path: "../SwiftTerm"),
    ],
    targets: [
        .target(name: "DesignSystem", exclude: ["Icons/LICENSE-lucide.txt"], resources: [.copy("Resources/surface-grain.rgba")], swiftSettings: sizeOptimized),
        // Wire and domain types from docs/protocol.md. No I/O.
        .target(name: "T3Protocol", swiftSettings: sizeOptimized),
        // Transport: HTTP auth, WebSocket RPC, reconnect supervisor, Keychain.
        .target(name: "T3Client", dependencies: ["T3Protocol"], swiftSettings: sizeOptimized),
        // Normalized state and reducers fed by T3Client streams.
        .target(name: "T3Store", dependencies: ["T3Protocol"], swiftSettings: sizeOptimized),
        // Screens built from DesignSystem components and fed by T3Store (sidebar, timeline, composer...).
        .target(name: "Features", dependencies: ["DesignSystem", "T3Store", "T3Protocol", .product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.copy("Resources/candy-town.gray"), .copy("Resources/mermaid.min.js.lzma"), .copy("Resources/LICENSE-mermaid.txt"), .copy("Resources/native-licenses.json"),
                         .copy("Resources/SymbolsNerdFontMono-Regular.ttf"), .copy("Resources/LICENSE-symbols-nerd-font.txt")],
                swiftSettings: sizeOptimized),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
        .testTarget(name: "T3ProtocolTests", dependencies: ["T3Protocol"]),
        .testTarget(name: "T3ClientTests", dependencies: ["T3Client"]),
        .testTarget(name: "T3StoreTests", dependencies: ["T3Store"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "DesignSystem", "T3Store", "T3Protocol", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    ]
)
