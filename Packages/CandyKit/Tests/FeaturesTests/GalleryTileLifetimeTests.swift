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

    /// Awaits `work`. Other suites in a full parallel run keep the cooperative pool busy for minutes, which only makes
    /// this return later; the limit is there for a real hang.
    static func settle(limit: Duration = .seconds(300), _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let (finished, done) = AsyncStream.makeStream(of: Bool.self)
        let loads = Task { @MainActor in
            await work()
            done.yield(true)
        }
        let watchdog = Task {
            try? await Task.sleep(for: limit)
            done.yield(false)
        }
        defer { watchdog.cancel(); loads.cancel(); done.finish() }
        for await ok in finished { return ok }
        return false
    }

    /// Awaits each view's load in flight.
    static func settle(_ views: [AsyncImageView]) async -> Bool {
        await settle { for view in views { await view.waitUntilLoaded() } }
    }

    static let starved = "did not finish in 5 minutes: the cooperative pool is starved or a load hung"

    /// A wall in a window whose tiles all show their pixels. `prefilled` puts the pixels in the wall's cache first, so
    /// tiles show without a load.
    private func loadedWall(_ window: NSWindow, prefilled: Bool = true) async throws -> (ThreadImageWallView, [GalleryImage]) {
        let wall = ThreadImageWallView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(wall)
        wall.masonry.makeLoader = { _ in { @Sendable _ in Self.pixels() } }
        #expect(wall.masonry.cache === ImageDecodeCache.gallery)
        // A cache of its own: AsyncImageCacheTests empties the shared ones in parallel.
        wall.masonry.cache = NSCache()
        // Keys of its own: `ImageDecodeCache` shares one in-flight decode per key across every cache, and other suites
        // build the same `fakeImages()`, whose keys differ only by the second they were made in.
        let images = ThreadImageWallTests.measuredImages().map { image in
            var image = image
            image.at = T3Timestamp(image.at.raw.replacingOccurrences(of: "Z", with: ".517Z"))
            return image
        }
        if prefilled, let pixels = Self.pixels() {
            for image in images { wall.masonry.cache.setObject(ImageDecodeCache.Cached(pixels, side: 4096), forKey: "\(image.pixelKey)|cover" as NSString) }
        }
        wall.images = images
        wall.layoutSubtreeIfNeeded()
        wall.masonry.relayout()
        // Sizes the new tiles, which starts their loads.
        wall.layoutSubtreeIfNeeded()
        for _ in 0..<3 {
            let settled = await Self.settle(wall.masonry.tiles.values.map(\.thumb))
            try #require(settled, "the tiles' loads \(Self.starved)")
            guard wall.masonry.tiles.values.contains(where: { $0.thumb.image == nil }) else { break }
            // A tile whose load failed is built again.
            wall.images = []
            wall.images = images
            wall.masonry.relayout()
            wall.layoutSubtreeIfNeeded()
        }
        let tiles = wall.masonry.tiles.values
        try #require(tiles.count >= 4 && tiles.allSatisfy { $0.thumb.image != nil },
                     "\(tiles.count) tiles, \(wall.masonry.frames.count) placed, \(tiles.filter { $0.thumb.image == nil }.count) without pixels, sizes \(tiles.map { $0.thumb.bounds.size }.prefix(2)), window \(wall.window != nil)")
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
        for _ in 0..<5 {
            let release = try #require(ImageDecodeCache.galleryRelease)
            let released = await Self.settle { await release.value }
            try #require(released, "the gallery release \(Self.starved)")
            // A wall another suite builds in parallel holds the gallery again, which cancels this release.
            guard release.isCancelled else { break }
            ImageDecodeCache.releaseGallery(after: .milliseconds(300))
        }
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
        let loaded = await Self.settle([view])
        try #require(loaded, "the first load \(Self.starved)")
        let old = try #require(view.image)
        view.reload(loader: { @Sendable _ in
            try? await Task.sleep(for: .milliseconds(200))
            return Self.pixels()
        })
        #expect(view.image === old, "the old picture stays while the new one loads")
        let reloaded = await Self.settle([view])
        try #require(reloaded, "the reload \(Self.starved)")
        #expect(view.image != nil && view.image !== old)
    }
}

extension GalleryTileLifetimeTests {
    /// A closed gallery lets go of its masonry. The scroll observer's block held the clip view, which holds the masonry
    /// as its document, so every gallery opened stayed in memory with its clip view and observer.
    @Test func aClosedWallFreesItsMasonry() {
        weak var masonry: GalleryMasonryView?
        autoreleasepool {
            let wall = ThreadImageWallView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            wall.layoutSubtreeIfNeeded()
            masonry = wall.masonry
            wall.releaseImages()
        }
        #expect(masonry == nil)
    }
}
