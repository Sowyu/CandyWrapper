// swift-tools-version: 6.0
import PackageDescription

// Release builds optimize for size: the shipped bundle stays well under the spec's 25 MB for benchmarks 2 to 8%
// slower (docs/perf/README.md, "Milestone 7 wrap-up"). Packages ignore the app project's settings.
let sizeOptimized: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "CandyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpaceModel", targets: ["SpaceModel"]),
        .library(name: "SpaceFields", targets: ["SpaceFields"]),
        .library(name: "SpacePlanning", targets: ["SpacePlanning"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "T3Protocol", targets: ["T3Protocol"]),
        .library(name: "T3Transport", targets: ["T3Transport"]),
        .library(name: "T3Client", targets: ["T3Client"]),
        .library(name: "T3Store", targets: ["T3Store"]),
        .library(name: "Features", targets: ["Features"]),
        .library(name: "SpaceCrypto", targets: ["SpaceCrypto"]),
        .library(name: "SpaceEngine", targets: ["SpaceEngine"]),
        .library(name: "SpaceLocal", targets: ["SpaceLocal"]),
        .executable(name: "candywrapper-helper", targets: ["CandyHelper"]),
    ],
    dependencies: [
        // SwiftTerm v1.19.0, vendored (Packages/SwiftTerm/README.md says why).
        .package(path: "../SwiftTerm"),
    ],
    targets: [
        // Private Space format. Foundation only, shared with the helper and Linux.
        .target(name: "SpaceModel", swiftSettings: sizeOptimized),
        // Pure field queries and conversion for Space views. No UI or storage.
        .target(name: "SpaceFields", dependencies: ["SpaceModel"], swiftSettings: sizeOptimized),
        // In-memory search and reminder plans. No UI, notifications or storage.
        .target(name: "SpacePlanning", dependencies: ["SpaceModel"], swiftSettings: sizeOptimized),
        .target(name: "DesignSystem", exclude: ["Icons/LICENSE-lucide.txt", "Icons/LICENSE-hugeicons.txt"], resources: [.copy("Resources/surface-grain.rgba")], swiftSettings: sizeOptimized),
        // Wire and domain types from docs/protocol.md. No I/O.
        .target(name: "T3Protocol", swiftSettings: sizeOptimized),
        // Bearer HTTP and the WebSocket RPC session, Foundation only, so the Linux helper shares them.
        .target(name: "T3Transport", dependencies: ["T3Protocol"], swiftSettings: sizeOptimized),
        // Transport: HTTP auth, T3 Connect, reconnect supervisor, Keychain. Re-exports T3Transport.
        .target(name: "T3Client", dependencies: ["T3Protocol", "T3Transport"], swiftSettings: sizeOptimized),
        // Normalized state and reducers fed by T3Client streams.
        .target(name: "T3Store", dependencies: ["T3Protocol"], swiftSettings: sizeOptimized),
        // The always-on Orchestrator relay for macOS and Linux (docs/orchestrator-helper.md). Foundation only.
        // libcurl's WebSocket frames for the helper on Linux (CurlRPCSocket); only imported there or with CANDY_CURL_WS.
        .systemLibrary(name: "CCurl"),
        .executableTarget(name: "CandyHelper", dependencies: ["T3Protocol", "T3Transport", "T3Store", "CCurl"], swiftSettings: sizeOptimized),
        // Space's keys, envelopes, blob chunks, recovery key and Keychain item (docs/space.md). CryptoKit and Security only.
        .target(name: "SpaceCrypto", swiftSettings: sizeOptimized),
        // Space's apply, rebase, text merge, conflict copies and undo (docs/space.md sections 2, 3 and 9). Pure logic.
        .target(name: "SpaceEngine", dependencies: ["SpaceModel"], swiftSettings: sizeOptimized),
        .target(name: "SpaceLocal", dependencies: ["SpaceModel", "SpaceCrypto"], swiftSettings: sizeOptimized),
        // Screens built from DesignSystem components and fed by T3Store (sidebar, timeline, composer...).
        .target(name: "Features", dependencies: ["DesignSystem", "T3Store", "T3Protocol", "SpaceModel", "SpaceEngine", "SpaceLocal", "SpaceCrypto", .product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.copy("Resources/candy-town.gray"), .copy("Resources/pele.global.js.lzma"), .copy("Resources/LICENSE-pele.txt"), .copy("Resources/native-licenses.json"),
                         .copy("Resources/SymbolsNerdFontMono-Regular.ttf"), .copy("Resources/LICENSE-symbols-nerd-font.txt")],
                swiftSettings: sizeOptimized),
        .testTarget(name: "SpaceModelTests", dependencies: ["SpaceModel"]),
        .testTarget(name: "SpaceFieldsTests", dependencies: ["SpaceFields", "SpaceModel"]),
        .testTarget(name: "SpacePlanningTests", dependencies: ["SpacePlanning", "SpaceModel"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
        .testTarget(name: "T3ProtocolTests", dependencies: ["T3Protocol"]),
        .testTarget(name: "T3ClientTests", dependencies: ["T3Client", "T3Transport"]),
        .testTarget(name: "T3StoreTests", dependencies: ["T3Store"]),
        .testTarget(name: "SpaceCryptoTests", dependencies: ["SpaceCrypto"]),
        .testTarget(name: "SpaceEngineTests", dependencies: ["SpaceEngine", "SpaceModel"]),
        .testTarget(name: "SpaceLocalTests", dependencies: ["SpaceLocal"]),
        .testTarget(name: "CandyHelperTests", dependencies: ["CandyHelper"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "SpaceModel", "DesignSystem", "T3Store", "T3Protocol", .product(name: "SwiftTerm", package: "SwiftTerm")], exclude: ["Fixtures"]),
    ]
)
