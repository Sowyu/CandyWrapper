import AppKit
import Testing
import WebKit
@testable import Features

@Suite @MainActor struct HtmlRenderPreviewCacheTests {
    static func image(side: Int = 8) -> NSImage {
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        let image = NSImage(size: NSSize(width: CGFloat(side), height: CGFloat(side)))
        image.addRepresentation(pixels)
        return image
    }

    static func bytes(_ image: NSImage) -> Int {
        let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return pixels.bytesPerRow * pixels.height
    }

    static func key(_ id: String = "page", width: CGFloat = 728, height: CGFloat = 240,
                    dark: Bool = false, scale: CGFloat = 2) -> HtmlRenderPreviewCache.Key {
        .init(attachmentId: id, size: NSSize(width: width, height: height), dark: dark, scale: scale)
    }

    @Test func leastRecentlyReadPreviewIsEvictedWithinTheByteLimit() {
        let image = Self.image(), bytes = Self.bytes(image)
        let cache = HtmlRenderPreviewCache(limit: bytes * 2)
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(image, for: Self.key("a"), generation: cache.generation)
        cache.insert(image, for: Self.key("b"), generation: cache.generation)
        #expect(cache.cost == bytes * 2)
        #expect(cache.image(for: Self.key("a")) === image)
        cache.insert(image, for: Self.key("c"), generation: cache.generation)
        #expect(cache.image(for: Self.key("b")) == nil)
        #expect(cache.image(for: Self.key("a")) === image)
        #expect(cache.image(for: Self.key("c")) === image)
        #expect(cache.cost == bytes * 2)
    }

    @Test func replacingAnEntryAccountsForItsNewPixelCost() {
        let small = Self.image(), large = Self.image(side: 16)
        let smallBytes = Self.bytes(small), largeBytes = Self.bytes(large)
        let cache = HtmlRenderPreviewCache(limit: largeBytes + smallBytes)
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(small, for: Self.key("a"), generation: cache.generation)
        cache.insert(small, for: Self.key("b"), generation: cache.generation)
        cache.insert(large, for: Self.key("a"), generation: cache.generation)
        #expect(cache.cost == largeBytes + smallBytes)
        #expect(cache.image(for: Self.key("a")) === large)
        cache.insert(small, for: Self.key("a"), generation: cache.generation)
        #expect(cache.cost == smallBytes * 2)
        #expect(cache.image(for: Self.key("a")) === small)
        #expect(cache.image(for: Self.key("b")) === small)
    }

    @Test func oversizedPreviewDoesNotEvictOtherAttachments() {
        let small = Self.image(), large = Self.image(side: 16)
        let cache = HtmlRenderPreviewCache(limit: Self.bytes(small))
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(small, for: Self.key("a"), generation: cache.generation)
        cache.insert(large, for: Self.key("b"), generation: cache.generation)
        #expect(cache.image(for: Self.key("b")) == nil)
        #expect(cache.image(for: Self.key("a")) === small)
        #expect(cache.cost == Self.bytes(small))
    }

    @Test func attachmentGeometryAppearanceAndBackingScaleMustAllMatch() {
        let cache = HtmlRenderPreviewCache(), image = Self.image()
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(image, for: Self.key(), generation: cache.generation)
        let misses = [Self.key("other"), Self.key(width: 729), Self.key(height: 241),
                      Self.key(dark: true), Self.key(scale: 1)]
        for key in misses { #expect(cache.image(for: key) == nil) }
        #expect(cache.image(for: Self.key()) === image)
    }

    @Test func clearAndDeactivateRejectCapturesFromThePreviousGeneration() {
        let cache = HtmlRenderPreviewCache(), image = Self.image(), key = Self.key()
        cache.insert(image, for: key, generation: cache.generation)
        #expect(cache.cost == 0, "a hidden document never accepts snapshots")
        cache.setActive(true)
        let old = cache.generation
        cache.insert(image, for: key, generation: old)
        cache.clear()
        #expect(cache.generation != old)
        #expect(cache.image(for: key) == nil)
        #expect(cache.cost == 0)
        cache.insert(image, for: key, generation: old)
        #expect(cache.image(for: key) == nil, "a capture completing after Force Reload stays discarded")
        cache.insert(image, for: key, generation: cache.generation)
        #expect(cache.image(for: key) === image)
        let beforeHide = cache.generation
        cache.setActive(false)
        #expect(cache.cost == 0)
        #expect(cache.image(for: key) == nil)
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(image, for: key, generation: beforeHide)
        #expect(cache.cost == 0, "showing the document again cannot revive its previous capture")
        cache.insert(image, for: key, generation: cache.generation)
        #expect(cache.image(for: key) === image)
    }
}

extension WebFrameSuites {
    @MainActor struct HtmlRenderCacheLifecycleTests {
        @Test func forceReloadClearsEveryShownDocumentsSnapshots() {
            let caches = [HtmlRenderPreviewCache(), HtmlRenderPreviewCache()]
            let key = HtmlRenderPreviewCacheTests.key(), image = HtmlRenderPreviewCacheTests.image()
            for cache in caches {
                cache.setActive(true)
                cache.insert(image, for: key, generation: cache.generation)
                #expect(cache.cost > 0)
            }
            defer { caches.forEach { $0.setActive(false) } }
            let generations = caches.map(\.generation)
            ThreadWebFrameBudget.clearData()
            for (cache, generation) in zip(caches, generations) {
                #expect(cache.cost == 0)
                #expect(cache.image(for: key) == nil)
                #expect(cache.generation != generation)
                cache.insert(image, for: key, generation: generation)
                #expect(cache.cost == 0)
            }
        }

        @Test func shownDocumentsKeepOneEphemeralStoreAcrossGapsBetweenPages() throws {
            let first = HtmlRenderPreviewCache(), second = HtmlRenderPreviewCache()
            first.setActive(true)
            second.setActive(true)
            defer { first.setActive(false); second.setActive(false) }
            let frame = ThreadWebFrameView()
            defer { frame.release() }
            let page = ThreadWebFrameView.Page(src: URL(string: "http://page.invalid/page.html")!, title: "Page", dark: false)
            frame.activate(page)
            let store = try #require(frame.webView?.configuration.websiteDataStore)
            #expect(!store.isPersistent)
            frame.release()
            #expect(ThreadWebFrameBudget.dataStore === store, "scrolling through a gap keeps the HTTP cache")
            first.setActive(false)
            #expect(ThreadWebFrameBudget.dataStore === store, "another shown document still owns it")
            frame.activate(page)
            #expect(frame.webView?.configuration.websiteDataStore === store)
            second.setActive(false)
            #expect(ThreadWebFrameBudget.dataStore === store, "a live page still owns it")
            frame.release()
            #expect(ThreadWebFrameBudget.dataStore !== store, "the final hidden document and released page drop the store")
        }

        @Test func destroyingAShownCacheReleasesItsStoreOwnership() {
            var cache: HtmlRenderPreviewCache? = HtmlRenderPreviewCache()
            cache?.setActive(true)
            let store = ThreadWebFrameBudget.dataStore
            weak var released = cache
            cache = nil
            #expect(released == nil)
            #expect(ThreadWebFrameBudget.dataStore !== store)
        }
    }
}
