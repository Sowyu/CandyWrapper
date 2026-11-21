import AppKit
import Testing
import T3Protocol
@testable import Features

/// The 1.16.0 gallery put loaded pictures back on the placeholder: every change to the wall's list rebuilt every tile,
/// and every rebuild could restart a transfer from its first byte.
@MainActor @Suite(.serialized) struct GalleryTileLifetimeTests {
    nonisolated static func pixels() -> CGImage? {
        CGContext(data: nil, width: 64, height: 44, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    /// A wall in a window whose tiles all show their pixels.
    private func loadedWall(_ window: NSWindow) async throws -> (ThreadImageWallView, [GalleryImage]) {
        let wall = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(wall)
        wall.masonry.makeLoader = { _ in { @Sendable _ in Self.pixels() } }
        let images = ThreadImageWallTests.measuredImages()
        wall.images = images
        wall.layoutSubtreeIfNeeded()
        wall.masonry.relayout()
        await ThreadImageGalleryTests.pump { !wall.masonry.tiles.isEmpty && wall.masonry.tiles.values.allSatisfy { $0.thumb.image != nil } }
        try #require(wall.masonry.tiles.count >= 4 && wall.masonry.tiles.values.allSatisfy { $0.thumb.image != nil })
        return (wall, images)
    }

    private func byKey(_ wall: ThreadImageWallView) -> [String: GalleryTileView] {
        Dictionary(uniqueKeysWithValues: wall.masonry.tiles.map { (wall.images[$0.key].pixelKey, $0.value) })
    }

    @Test func aListChangeKeepsEveryTileAndItsPixels() async throws {
        let window = ThreadImageWallTests.window()
        defer { window.contentView = nil; window.close() }
        let (wall, images) = try await loadedWall(window)
        let before = byKey(wall)
        // A projection push that changes the list but no picture: one more view of the first.
        var next = images
        next[0].views = 2
        wall.images = next
        let after = byKey(wall)
        #expect(after.count == before.count)
        for (key, tile) in after {
            #expect(tile === before[key], "the same tile view for \(key)")
            #expect(tile.thumb.image != nil, "no placeholder for \(key)")
        }
    }

    @Test func aHashMergeKeepsTheSurvivorsPixels() async throws {
        let window = ThreadImageWallTests.window()
        defer { window.contentView = nil; window.close() }
        let (wall, images) = try await loadedWall(window)
        let before = byKey(wall)
        // Two sources turn out to hold the same bytes: the newer stays and every later picture moves up one.
        var next = images
        next[1].contentHash = "same"
        next[2].contentHash = "same"
        let merged = ThreadImageGallery.merge([next])
        #expect(merged.count == images.count - 1)
        wall.images = merged
        let after = byKey(wall)
        #expect(after[images[2].pixelKey] == nil, "the merged-away picture lost its tile")
        #expect(before[images[2].pixelKey]?.superview == nil)
        for (key, tile) in after where before[key] != nil {
            #expect(tile === before[key], "the same tile view for \(key)")
            #expect(tile.thumb.image != nil, "no placeholder for \(key)")
        }
        // A click on a moved tile opens its new index.
        let moved = try #require(wall.masonry.tiles[2])
        var opened: Int?
        wall.masonry.onSelect = { opened = $0 }
        moved.action?()
        #expect(opened == 2)
    }
}

extension GalleryTileLifetimeTests {
    /// A tile that leaves and comes back, or a gallery reopened soon after closing, shows its pixels in the same pass
    /// from the wall's own cache, and that cache empties once the gallery has stayed closed.
    @Test func aReturningTileShowsAtOnceAndAClosedGalleryLetsGo() async throws {
        let window = ThreadImageWallTests.window()
        defer { window.contentView = nil; window.close() }
        let (wall, images) = try await loadedWall(window)
        #expect(wall.masonry.cache === ImageDecodeCache.gallery)
        let cached = images.filter { ImageDecodeCache.gallery.object(forKey: "\($0.pixelKey)|cover" as NSString) != nil }
        #expect(cached.count == wall.masonry.tiles.count, "every tile's decode is kept")
        // Tiles go, as when they scroll a viewport away or the gallery closes, and come back.
        wall.images = []
        wall.images = images
        wall.masonry.relayout()
        // The layout pass before the window draws sizes the new tiles; no turn of the run loop.
        wall.layoutSubtreeIfNeeded()
        #expect(!wall.masonry.tiles.isEmpty)
        #expect(wall.masonry.tiles.values.allSatisfy { $0.thumb.image != nil }, "no placeholder for a picture seen before")
        // The timeline's cache holds none of them.
        #expect(images.allSatisfy { ImageDecodeCache.memory.object(forKey: "\($0.pixelKey)|cover" as NSString) == nil })
        ImageDecodeCache.releaseGallery(after: .milliseconds(20))
        await ThreadImageGalleryTests.pump { ImageDecodeCache.gallery.object(forKey: "\(images[0].pixelKey)|cover" as NSString) == nil }
        #expect(images.allSatisfy { ImageDecodeCache.gallery.object(forKey: "\($0.pixelKey)|cover" as NSString) == nil })
    }
}

extension GalleryTileLifetimeTests {
    /// A kept reply picture found stale on the server stays on screen until its new bytes are decoded.
    @Test func aStalePictureStaysUntilItsReplacementIsReady() async throws {
        let window = ThreadImageWallTests.window()
        defer { window.contentView = nil; window.close() }
        let view = AsyncImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 44))
        window.contentView!.addSubview(view)
        view.set(key: "stale-" + UUID().uuidString, fallbackText: "x", loader: { @Sendable _ in Self.pixels() })
        await ThreadImageGalleryTests.pump { view.image != nil }
        let old = try #require(view.image)
        view.reload(loader: { @Sendable _ in
            try? await Task.sleep(for: .milliseconds(200))
            return Self.pixels()
        })
        #expect(view.image === old, "the old picture stays while the new one loads")
        await ThreadImageGalleryTests.pump { view.image !== old }
        #expect(view.image != nil && view.image !== old)
    }
}
