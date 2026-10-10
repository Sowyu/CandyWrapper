import Foundation
import Testing
@testable import DesignSystem

@MainActor
struct GrainTileTests {
    /// The shipped tile is `SurfaceGrain.makeTile`'s output. Regenerate it with CANDY_WRITE_GRAIN=1.
    @Test func shippedTileMatchesTheGenerator() throws {
        let generated = SurfaceGrain.makeTile(pixels: 512, scale: 2)
        let bytes = try #require(generated.dataProvider?.data) as Data
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/DesignSystem/Resources/surface-grain.rgba").standardized
        if ProcessInfo.processInfo.environment["CANDY_WRITE_GRAIN"] != nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
        let shipped = try #require(SurfaceGrain.shippedTile())
        #expect(shipped.dataProvider?.data as Data? == bytes)
    }
}
