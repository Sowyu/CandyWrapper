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
    /// `prefilled` puts the pixels in the wall's cache first, so tiles show without a task: in a full parallel run the
    /// cooperative pool can be busy for over a minute, longer than any wait here.
    private func loadedWall(_ window: NSWindow, prefilled: Bool = true) async throws -> (ThreadImageWallView, [GalleryImage]) {
        let wall = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(wall)
        wall.masonry.makeLoader = { _ in { @Sendable _ in Self.pixels() } }
        #expect(wall.masonry.cache === ImageDecodeCache.gallery)
        // A cache of its own: AsyncImageCacheTests empties the shared ones in parallel.
        wall.masonry.cache = NSCache()
        let images = ThreadImageWallTests.measuredImages()
        if prefilled, let pixels = Self.pixels() {
            for image in images { wall.masonry.cache.setObject(ImageDecodeCache.Cached(pixels, side: 4096), forKey: "\(image.pixelKey)|cover" as NSString) }
        }
        wall.images = images
        wall.layoutSubtreeIfNeeded()
        wall.masonry.relayout()
        // Up to 60 s: in a full parallel run other suites hold the main actor that long. A parallel
        // `AsyncImageView.clearMemory()` cancels decodes in flight, so a tile that failed that way is built again.
        let end = Date().addingTimeInterval(60)
        while !(!wall.masonry.tiles.isEmpty && wall.masonry.tiles.values.allSatisfy { $0.thumb.image != nil }), Date() < end {
            try? await Task.sleep(for: .milliseconds(50))
            if wall.masonry.tiles.values.contains(where: { $0.thumb.failureState != nil }) {
                wall.images = []
                wall.images = images
                wall.layoutSubtreeIfNeeded()
                wall.masonry.relayout()
            }
        }
        let tiles = wall.masonry.tiles.values
        try #require(tiles.count >= 4 && tiles.allSatisfy { $0.thumb.image != nil },
                     "\(tiles.count) tiles, \(wall.masonry.frames.count) placed, \(tiles.filter { $0.thumb.image == nil }.count) without pixels, \(tiles.filter { $0.thumb.failureState != nil }.count) failed, sizes \(tiles.map { $0.thumb.bounds.size }.prefix(2)), window \(wall.window != nil)")
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
        let (wall, images) = try await loadedWall(window, prefilled: false)
        let cache = wall.masonry.cache
        let cached = images.filter { cache.object(forKey: "\($0.pixelKey)|cover" as NSString) != nil }
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
        // The gallery's own cache lets go a while after it closes, and not before.
        let probe = "release-" + UUID().uuidString as NSString
        ImageDecodeCache.gallery.setObject(ImageDecodeCache.Cached(try #require(Self.pixels()), side: 64), forKey: probe)
        ImageDecodeCache.releaseGallery(after: .milliseconds(300))
        #expect(ImageDecodeCache.gallery.object(forKey: probe) != nil)
        let end = Date().addingTimeInterval(60)
        while ImageDecodeCache.gallery.object(forKey: probe) != nil, Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(ImageDecodeCache.gallery.object(forKey: probe) == nil)
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
