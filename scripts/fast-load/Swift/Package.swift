// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = ProcessInfo.processInfo.environment["CANDY_BENCH_PACKAGE"] ?? "../../../Packages/CandyKit"
let httpFirst = ProcessInfo.processInfo.environment["CANDY_BENCH_HTTP_FIRST"] == "1"
let fastWire = ProcessInfo.processInfo.environment["CANDY_BENCH_FAST_WIRE"] == "1"
let package = Package(
    name: "CandyFastLoad",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: root)],
    targets: [.executableTarget(name: "candy-fast-load", dependencies: [
        .product(name: "T3Client", package: "CandyKit"),
        .product(name: "T3Store", package: "CandyKit")
    ], path: "Sources", swiftSettings: (httpFirst ? [.define("CANDY_HTTP_FIRST")] : []) + (fastWire ? [.define("CANDY_FAST_WIRE")] : []))]
)
