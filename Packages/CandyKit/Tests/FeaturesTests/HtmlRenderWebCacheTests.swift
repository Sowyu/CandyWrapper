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
            frame.webViewWebContentProcessDidTerminate(ThreadWebView(frame: .zero, configuration: WKWebViewConfiguration()))
            #expect(frame.webView === web, "a retired web view cannot terminate the current page")
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
            let cache = HtmlRenderWebCache()
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

        @Test func aHostRetiresAfterOneHandoff() {
            let cache = HtmlRenderWebCache()
            cache.setActive(true)
            defer { cache.setActive(false) }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = ThreadWebView(frame: .zero, configuration: config)
            cache.activated(web)
            cache.recycle(web)
            #expect(cache.takeWebView() === web)
            cache.activated(web)
            cache.recycle(web)
            #expect(cache.takeWebView() == nil, "removed image documents cannot accumulate in one host")
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
            let cache = HtmlRenderWebCache()
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
            frame.htmlCache = cache
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
            let cache = HtmlRenderWebCache()
            cache.setActive(true)
            let first = ThreadWebFrameView(), second = ThreadWebFrameView()
            first.htmlCache = cache
            second.htmlCache = cache
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
            #expect(web.isHidden, "the outgoing iframe cannot flash before replacement")
            #expect(web.configuration.userContentController.userScripts.count == 1, "old bridge scripts never accumulate")
            var heights: [Double] = []
            second.onMessage = { if let height = HtmlRenderTheme.contentHeight($0) { heights.append(height) } }
            let message = #"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":222}}"#
            second.received(message, isMainFrame: true, token: second.loadToken)
            #expect(heights.isEmpty, "the outgoing iframe can still post before the replacement script runs")
            second.received(["t3FrameStarted": first.loadToken], isMainFrame: true, token: second.loadToken)
            second.received(message, isMainFrame: true, token: second.loadToken)
            #expect(heights.isEmpty, "a retired iframe cannot reopen the new bridge")
            second.received(["t3FrameStarted": second.loadToken], isMainFrame: true, token: second.loadToken)
            #expect(!web.isHidden, "the new iframe can paint as soon as the outgoing one is removed")
            second.received(message, isMainFrame: true, token: second.loadToken)
            #expect(heights.isEmpty, "intermediate heights wait for the image load")
            #expect(second.shortcutsPosted, "height coalescing does not delay the shortcut handshake")
            let final = #"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":333}}"#
            second.received(final, isMainFrame: true, token: second.loadToken)
            second.received(["t3FrameLoaded": second.loadToken], isMainFrame: true, token: second.loadToken)
            #expect(heights == [333], "only the last loading height reaches the native timeline")
            #expect(!web.isHidden)
        }

        @Test func aSpareClearsItsPageAndCannotReturnAfterHide() async {
            let cache = HtmlRenderWebCache()
            cache.setActive(true)
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = ThreadWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: config)
            web.loadHTMLString("<html><body><iframe id='f' srcdoc='<p>Old page</p>'></iframe></body></html>", baseURL: URL(string: "about:blank"))
            #expect(await eventually { web.url?.absoluteString == "about:blank" && !web.isLoading })
            cache.recycle(web)
            var evaluation = "not evaluated"
            let cleared = await eventually(seconds: 3) {
                do {
                    let removed = try await web.callAsyncJavaScript("return document.getElementById('f') === null", arguments: [:],
                                                                   in: nil, contentWorld: .world(name: "t3-host"))
                    evaluation = String(describing: removed)
                    return removed as? Bool == true
                } catch {
                    evaluation = String(describing: error)
                    return false
                }
            }
            #expect(cleared, Comment(rawValue: evaluation))
            cache.setActive(false)
            cache.setActive(true)
            defer { cache.setActive(false) }
            #expect(cache.takeWebView() == nil)
        }

        @Test func forceReloadDiscardsEveryShownDocumentsSpare() {
            let caches = [HtmlRenderWebCache(), HtmlRenderWebCache()]
            for cache in caches {
                cache.setActive(true)
                cache.recycle(ThreadWebView(frame: .zero, configuration: WKWebViewConfiguration()))
            }
            defer { caches.forEach { $0.setActive(false) } }
            ThreadWebFrameBudget.clearData()
            for cache in caches { #expect(cache.takeWebView() == nil) }
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
