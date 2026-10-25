import AppKit
import Testing
import WebKit
import T3Store
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

    static func png(_ image: NSImage) -> Data {
        NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            .representation(using: .png, properties: [:])!
    }

    static func bytes(_ image: NSImage) -> Int { png(image).count }

    static func rgba(_ image: CGImage) -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }

    static func sameImage(_ image: NSImage?, _ expected: NSImage) -> Bool {
        guard let a = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let b = expected.cgImage(forProposedRect: nil, context: nil, hints: nil),
              a.width == b.width, a.height == b.height else { return false }
        return rgba(a) == rgba(b)
    }

    @Test func encodedPreviewsKeepTheirPixels() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
        for y in 0..<8 { for x in 0..<8 {
            bitmap.setColor(NSColor(srgbRed: CGFloat(x) / 7, green: CGFloat(y) / 7, blue: 0.4, alpha: 1), atX: x, y: y)
        } }
        let original = try #require(bitmap.cgImage)
        let data = try #require(await HtmlRenderPreviewEncoder.shared.png(.init(image: original)))
        let image = try #require(NSImage(data: data))
        let decoded = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(Self.rgba(original) == Self.rgba(decoded))
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
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: Self.key("a"), generation: cache.generation)
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: Self.key("b"), generation: cache.generation)
        #expect(cache.cost == bytes * 2)
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: Self.key("a")), image))
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: Self.key("c"), generation: cache.generation)
        #expect(cache.image(for: Self.key("b")) == nil)
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: Self.key("a")), image))
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: Self.key("c")), image))
        #expect(cache.cost == bytes * 2)
    }

    @Test func replacingAnEntryAccountsForItsNewPixelCost() {
        let small = Self.image(), large = Self.image(side: 16)
        let smallBytes = Self.bytes(small), largeBytes = Self.bytes(large)
        let cache = HtmlRenderPreviewCache(limit: largeBytes + smallBytes)
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(HtmlRenderPreviewCacheTests.png(small), for: Self.key("a"), generation: cache.generation)
        cache.insert(HtmlRenderPreviewCacheTests.png(small), for: Self.key("b"), generation: cache.generation)
        cache.insert(HtmlRenderPreviewCacheTests.png(large), for: Self.key("a"), generation: cache.generation)
        #expect(cache.cost == largeBytes + smallBytes)
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: Self.key("a")), large))
        cache.insert(HtmlRenderPreviewCacheTests.png(small), for: Self.key("a"), generation: cache.generation)
        #expect(cache.cost == smallBytes * 2)
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: Self.key("a")), small))
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: Self.key("b")), small))
    }

    @Test func oversizedPreviewDoesNotEvictOtherAttachments() {
        let small = Self.image(), large = Self.image(side: 16)
        let cache = HtmlRenderPreviewCache(limit: Self.bytes(small))
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(HtmlRenderPreviewCacheTests.png(small), for: Self.key("a"), generation: cache.generation)
        cache.insert(HtmlRenderPreviewCacheTests.png(large), for: Self.key("b"), generation: cache.generation)
        #expect(cache.image(for: Self.key("b")) == nil)
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: Self.key("a")), small))
        #expect(cache.cost == Self.bytes(small))
    }

    @Test func attachmentGeometryAppearanceAndBackingScaleMustAllMatch() {
        let cache = HtmlRenderPreviewCache(), image = Self.image()
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: Self.key(), generation: cache.generation)
        let misses = [Self.key("other"), Self.key(width: 729), Self.key(height: 241),
                      Self.key(dark: true), Self.key(scale: 1)]
        for key in misses { #expect(cache.image(for: key) == nil) }
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: Self.key()), image))
    }

    @Test func clearAndDeactivateRejectCapturesFromThePreviousGeneration() {
        let cache = HtmlRenderPreviewCache(), image = Self.image(), key = Self.key()
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: key, generation: cache.generation)
        #expect(cache.cost == 0, "a hidden document never accepts snapshots")
        cache.setActive(true)
        let old = cache.generation
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: key, generation: old)
        cache.clear()
        #expect(cache.generation != old)
        #expect(cache.image(for: key) == nil)
        #expect(cache.cost == 0)
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: key, generation: old)
        #expect(cache.image(for: key) == nil, "a capture completing after Force Reload stays discarded")
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: key, generation: cache.generation)
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: key), image))
        let beforeHide = cache.generation
        cache.setActive(false)
        #expect(cache.cost == 0)
        #expect(cache.image(for: key) == nil)
        cache.setActive(true)
        defer { cache.setActive(false) }
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: key, generation: beforeHide)
        #expect(cache.cost == 0, "showing the document again cannot revive its previous capture")
        cache.insert(HtmlRenderPreviewCacheTests.png(image), for: key, generation: cache.generation)
        #expect(HtmlRenderPreviewCacheTests.sameImage(cache.image(for: key), image))
    }
}

extension WebFrameSuites {
    @MainActor struct HtmlRenderCacheLifecycleTests {
        @Test func retiredMessagesAndNavigationCompletionsCannotReviveAFrame() throws {
            let cache = HtmlRenderPreviewCache()
            cache.setActive(true)
            let frame = ThreadWebFrameView()
            frame.previewCache = cache
            defer { cache.setActive(false); frame.release() }
            frame.activate(.init(src: URL(string: "http://page.invalid/page.html")!, title: "Current", dark: false))
            let web = try #require(frame.webView)
            var messages = 0
            frame.onMessage = { _ in messages += 1 }
            frame.received(#"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":123}}"#,
                           isMainFrame: true, token: "retired activation")
            #expect(messages == 0)
            let retired = try #require(web.loadHTMLString("<html></html>", baseURL: URL(string: "about:blank")))
            frame.webView(web, didFinish: retired)
            frame.release()
            #expect(cache.takeWebView() == nil, "an unrelated completion cannot mark the current host ready for reuse")
        }

        @Test func twoVisibleViewsDoNotKeepAnEmptyThirdHost() {
            let cache = HtmlRenderPreviewCache()
            cache.setActive(true)
            defer { cache.setActive(false) }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let first = ThreadWebView(frame: .zero, configuration: config)
            let second = ThreadWebView(frame: .zero, configuration: config)
            let spare = ThreadWebView(frame: .zero, configuration: config)
            cache.recycle(spare)
            cache.activated(first)
            cache.activated(second)
            #expect(cache.takeWebView() == nil)
            cache.recycle(first, reusable: false)
            cache.recycle(spare)
            #expect(cache.takeWebView() === spare, "one visible frame can share one empty host")
        }

        @MainActor final class Pages: NSObject, WKURLSchemeHandler {
            func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
                let url = task.request.url!
                let height = url.lastPathComponent == "second" ? 222 : 333
                let html = """
                <html><body><script>window.addEventListener('load',()=>setTimeout(()=>parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/size-changed',params:{height:\(height)}},'*'),0));</script></body></html>
                """
                let data = Data(html.utf8)
                task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
                task.didReceive(data)
                task.didFinish()
            }
            func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
        }

        @Test func reusedHostsForwardTheNewIframesHeightWithOneBridge() async throws {
            let cache = HtmlRenderPreviewCache()
            cache.setActive(true)
            let config = WKWebViewConfiguration()
            config.websiteDataStore = ThreadWebFrameBudget.dataStore
            config.setURLSchemeHandler(Pages(), forURLScheme: "cw-html-test")
            let web = ThreadWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: config)
            web.htmlHostOrigin = "cw-html-test://sandbox"
            let first = ThreadWebFrameView.Page(src: URL(string: "cw-html-test://sandbox/first")!, title: "First", dark: false)
            web.loadHTMLString(ThreadWebFrameView.hostPage(first), baseURL: URL(string: "about:blank"))
            #expect(await eventually { web.url != nil && !web.isLoading })
            let frame = ThreadWebFrameView(frame: web.frame)
            frame.previewCache = cache
            var heights: [Double] = []
            frame.onMessage = { if let height = HtmlRenderTheme.contentHeight($0) { heights.append(height) } }
            defer { cache.setActive(false); frame.release() }
            cache.recycle(web)
            frame.activate(.init(src: URL(string: "cw-html-test://sandbox/second")!, title: "Second", dark: true))
            #expect(frame.webView === web)
            #expect(await eventually { heights == [222] })
            frame.activate(.init(src: URL(string: "cw-html-test://sandbox/third")!, title: "Third", dark: false))
            #expect(frame.webView === web)
            #expect(await eventually { heights == [222, 333] })
            #expect(web.backForwardList.backList.isEmpty, "iframe handoffs do not retain whole page history")
            #expect(web.configuration.userContentController.userScripts.count == 1)
        }

        @Test func aSameTurnHandoffReusesOnlyOneViewAndReplacesItsBridge() throws {
            let cache = HtmlRenderPreviewCache()
            cache.setActive(true)
            let first = ThreadWebFrameView(), second = ThreadWebFrameView()
            first.previewCache = cache
            second.previewCache = cache
            defer { cache.setActive(false); first.release(); second.release() }
            let src = URL(string: "http://page.invalid/page.html")!
            first.activate(.init(src: src, title: "First", dark: false))
            let web = try #require(first.webView)
            first.release()
            cache.recycle(web)
            #expect(!first.isLive)
            #expect(web.configuration.userContentController.userScripts.isEmpty)
            second.activate(.init(src: src, title: "Second", dark: true))
            #expect(second.webView === web, "the next row can use the process without retaining the old frame")
            #expect(web.configuration.userContentController.userScripts.count == 1, "old bridge scripts never accumulate")
        }

        @Test func aSpareClearsItsPageAndCannotReturnAfterHide() async {
            let cache = HtmlRenderPreviewCache()
            cache.setActive(true)
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = ThreadWebView(frame: .zero, configuration: config)
            web.loadHTMLString("<html><body><iframe id='f' srcdoc='<p>Old page</p>'></iframe></body></html>", baseURL: URL(string: "about:blank"))
            #expect(await eventually { web.url?.absoluteString == "about:blank" && !web.isLoading })
            cache.recycle(web)
            #expect(await eventually {
                let removed = try? await web.callAsyncJavaScript("return document.getElementById('f') === null", arguments: [:],
                                                               in: nil, in: .world(name: "t3-host"))
                return removed as? Bool == true
            })
            cache.setActive(false)
            cache.setActive(true)
            defer { cache.setActive(false) }
            #expect(cache.takeWebView() == nil)
        }

        @Test func forceReloadClearsEveryShownDocumentsSnapshots() {
            let caches = [HtmlRenderPreviewCache(), HtmlRenderPreviewCache()]
            let key = HtmlRenderPreviewCacheTests.key(), image = HtmlRenderPreviewCacheTests.image()
            for cache in caches {
                cache.setActive(true)
                cache.insert(HtmlRenderPreviewCacheTests.png(image), for: key, generation: cache.generation)
                #expect(cache.cost > 0)
            }
            defer { caches.forEach { $0.setActive(false) } }
            let generations = caches.map(\.generation)
            ThreadWebFrameBudget.clearData()
            for (cache, generation) in zip(caches, generations) {
                #expect(cache.cost == 0)
                #expect(cache.image(for: key) == nil)
                #expect(cache.generation != generation)
                cache.insert(HtmlRenderPreviewCacheTests.png(image), for: key, generation: generation)
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
