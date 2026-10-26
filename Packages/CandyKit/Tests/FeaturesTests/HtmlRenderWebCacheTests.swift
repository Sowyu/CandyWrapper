import AppKit
import Testing
import WebKit
import T3Store
@testable import Features

extension WebFrameSuites {
    @MainActor struct HtmlRenderCacheLifecycleTests {
        @Test func retiredMessagesAndNavigationCompletionsCannotReviveAFrame() throws {
            let cache = HtmlRenderWebCache()
            cache.setActive(true)
            let frame = ThreadWebFrameView()
            frame.htmlCache = cache
            defer { cache.setActive(false); frame.release() }
            frame.activate(.init(src: URL(string: "http://page.invalid/page.html")!, title: "Current", dark: false))
            let web = try #require(frame.webView)
            var heights: [Double] = []
            frame.onMessage = { if let height = HtmlRenderTheme.contentHeight($0) { heights.append(height) } }
            let old = #"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":123}}"#
            frame.received(old, isMainFrame: true, token: "retired activation")
            #expect(heights.isEmpty)
            frame.received(old, isMainFrame: true, token: frame.loadToken)
            let latest = #"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":333}}"#
            frame.received(latest, isMainFrame: true, token: frame.loadToken)
            #expect(heights.isEmpty, "loading heights are coalesced")
            #expect(frame.shortcutsPosted, "height coalescing does not delay shortcuts")
            let navigation = try #require(frame.hostNavigation)
            let retired = try #require(web.loadHTMLString("<html></html>", baseURL: URL(string: "about:blank")))
            frame.webView(web, didFinish: retired)
            #expect(heights.isEmpty, "a retired completion cannot flush the current height")
            frame.webViewWebContentProcessDidTerminate(ThreadWebView(frame: .zero, configuration: WKWebViewConfiguration()))
            #expect(frame.webView === web)
            frame.webView(web, didFinish: navigation)
            #expect(heights == [333], "only the last loading report reaches layout")
            frame.release()
            frame.received(latest, isMainFrame: true, token: frame.loadToken)
            #expect(heights == [333])
        }

        @Test func forceReloadClearsEveryShownDocumentsPixels() {
            let caches = [HtmlRenderWebCache(), HtmlRenderWebCache()]
            let image = HtmlRenderPixelCacheTests.image(), key = HtmlRenderPixelCacheTests.key()
            for cache in caches {
                cache.setActive(true)
                cache.insert(image, for: key, generation: cache.generation)
            }
            defer { caches.forEach { $0.setActive(false) } }
            let generations = caches.map(\.generation)
            ThreadWebFrameBudget.clearData()
            for (cache, old) in zip(caches, generations) {
                #expect(cache.cost == 0)
                cache.insert(image, for: key, generation: old)
                #expect(cache.cost == 0)
            }
        }

        @Test func shownDocumentsKeepOneEphemeralStoreAcrossGapsBetweenPages() throws {
            let first = HtmlRenderWebCache(), second = HtmlRenderWebCache()
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
            var cache: HtmlRenderWebCache? = HtmlRenderWebCache()
            cache?.setActive(true)
            let store = ThreadWebFrameBudget.dataStore
            weak var released = cache
            cache = nil
            #expect(released == nil)
            #expect(ThreadWebFrameBudget.dataStore !== store)
        }
    }

    @MainActor struct HtmlRenderPixelCacheTests {
        static func image(side: Int = 8) -> CGImage {
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.6))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            return context.makeImage()!
        }

        static func key(_ id: String = "page", width: CGFloat = 728, height: CGFloat = 240,
                        dark: Bool = false, scale: CGFloat = 2) -> HtmlRenderWebCache.Key {
            .init(attachmentId: id, size: NSSize(width: width, height: height), dark: dark, scale: scale)
        }

        @Test func pixelsRoundTripWithoutEncodingAndUnusedContentCanBeDiscarded() throws {
            let image = Self.image()
            let cache = HtmlRenderWebCache()
            cache.setActive(true)
            defer { cache.setActive(false) }
            cache.insert(image, for: Self.key(), generation: cache.generation)
            #expect(cache.cost == image.bytesPerRow * image.height)
            try autoreleasepool {
                let held = try #require(cache.image(for: Self.key()))
                cache.discardUnusedPixels()
                let restored = try #require(held.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #expect(restored.bitsPerPixel == image.bitsPerPixel)
                #expect(restored.bitmapInfo == image.bitmapInfo)
                #expect(restored.colorSpace == image.colorSpace)
                #expect((restored.dataProvider?.data as Data?) == (image.dataProvider?.data as Data?))
            }
            cache.discardUnusedPixels()
            #expect(cache.image(for: Self.key()) == nil, "memory pressure is a safe cache miss")
            #expect(cache.cost == 0)
        }

        @Test func lruUsesExactBitmapBytesAndRejectsOversizedEntries() {
            let image = Self.image(), bytes = image.bytesPerRow * image.height
            let cache = HtmlRenderWebCache(limit: bytes * 2)
            cache.setActive(true)
            defer { cache.setActive(false) }
            cache.insert(image, for: Self.key("a"), generation: cache.generation)
            cache.insert(image, for: Self.key("b"), generation: cache.generation)
            #expect(cache.image(for: Self.key("a")) != nil)
            cache.insert(image, for: Self.key("c"), generation: cache.generation)
            #expect(cache.image(for: Self.key("b")) == nil)
            #expect(cache.contains(Self.key("a")))
            cache.insert(Self.image(side: 128), for: Self.key("huge"), generation: cache.generation)
            #expect(!cache.contains(Self.key("huge")))
            #expect(cache.cost == bytes * 2)
        }

        @Test func replacementGeometryThemeScaleAndGenerationStayIndependent() {
            let image = Self.image(), larger = Self.image(side: 16)
            let cache = HtmlRenderWebCache()
            cache.setActive(true)
            defer { cache.setActive(false) }
            cache.insert(image, for: Self.key(), generation: cache.generation)
            cache.insert(larger, for: Self.key(), generation: cache.generation)
            #expect(cache.cost == larger.bytesPerRow * larger.height)
            for key in [Self.key("other"), Self.key(width: 729), Self.key(height: 241), Self.key(dark: true), Self.key(scale: 1)] {
                #expect(cache.image(for: key) == nil)
            }
            let old = cache.generation
            cache.clear()
            cache.insert(image, for: Self.key(), generation: old)
            #expect(cache.cost == 0)
            cache.insert(image, for: Self.key(), generation: cache.generation)
            #expect(cache.contains(Self.key()))
            cache.setActive(false)
            #expect(cache.cost == 0)
            cache.insert(image, for: Self.key(), generation: cache.generation)
            #expect(cache.cost == 0, "a hidden pane never accepts pixels")
        }
    }
}
