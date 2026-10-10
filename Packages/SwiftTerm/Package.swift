// swift-tools-version: 6.0
import PackageDescription

// SwiftTerm v1.19.0 (MIT, see LICENSE), vendored from github.com/migueldeicaza/SwiftTerm at
// 464df5207fc2432e16c9a23abe538187196daf5f. See README.md for why it is vendored and what was left out.
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm")],
    swiftLanguageModes: [.v5]
)
