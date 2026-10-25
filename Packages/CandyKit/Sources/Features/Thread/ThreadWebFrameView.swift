import AppKit
import DesignSystem
import T3Protocol
import T3Store
import WebKit

/// A sandboxed agent document in the timeline, the way T3 frames one (BrowserDocumentFrame.tsx `HtmlRenderDocument`,
/// McpAppFrame.tsx): an `<iframe sandbox="allow-scripts allow-forms">` (never `allow-same-origin`) inside a blank
/// host page whose own policy allows nothing but that frame. The bridge lives in an isolated script world the
/// page cannot reach, forwards only messages from the frame's own window, and posts back into it. The document
/// never navigates: each activation loads the frame once; anything after that is refused. A shown HTML chat can
/// reuse an empty host for another attachment from that origin after discarding the old iframe.
///
/// The web view exists only while `activate` holds it. `ThreadWebFrameBudget` keeps at most a few alive across
/// the app; the timeline releases a row's view when the row scrolls away or the thread closes.
///
/// A workspace HTML file (`Kind.workspaceFile`, BrowserDocumentFrame.tsx:53-59) uses the same host page with T3's
/// file flags, `allow-scripts allow-forms allow-popups allow-downloads`, no bridge, its own data store and no budget.
@MainActor
final class ThreadWebFrameView: NSView, WKNavigationDelegate {
    #if DEBUG
    /// Only the opt-in sandbox benchmark installs this observer.
    static var benchmarkObserver: ((String, Page, ThreadWebFrameView, JSONValue?) -> Void)?
    #endif

    enum Kind: Equatable {
        /// An agent's HTML render or an MCP app: bridge on, one frame load.
        case agent
        /// A workspace HTML file preview: no bridge; links the reader clicks open in the browser.
        case workspaceFile

        /// The iframe `sandbox` attribute; never `allow-same-origin` or `allow-top-navigation`.
        var sandbox: String {
            switch self {
            case .agent: "allow-scripts allow-forms"
            case .workspaceFile: "allow-scripts allow-forms allow-popups allow-downloads"
            }
        }
    }

    struct Page: Equatable {
        var src: URL
        var title: String
        /// The iframe `allow` attribute (an MCP App's permissions).
        var allow: String = ""
        var dark: Bool
        var kind: Kind = .agent
    }

    /// Where a navigation would land.
    enum NavigationTarget { case newWindow, host, frame }

    enum NavigationDecision: Equatable {
        case allow
        case cancel
        /// Cancel here and hand the link to the system browser.
        case openExternally(URL)
    }

    /// A message the framed document posted.
    var onMessage: ((JSONValue) -> Void)?
    /// The document tried to load a second time (an MCP App left its page).
    var onNavigatedAway: (() -> Void)?
    /// The budget took the web view back.
    var onEvicted: (() -> Void)?
    /// Whether the frame counts against `ThreadWebFrameBudget`. The full screen dialog's doesn't: opening it would
    /// blank the oldest render on screen, and a live turn's new renders would blank the dialog.
    var budgeted = true
    private(set) var webView: ThreadWebView?
    private var page: Page?
    private var hostLoaded = false
    private var hostNavigation: WKNavigation?
    private var frameLoads = 0
    /// The last time the reader clicked or typed in the frame: links open only right after that.
    private(set) var lastUserActivity = Date.distantPast
    /// An HTML render was told which app shortcuts it may pass on.
    var shortcutsPosted = false
    /// The theme the page was loaded with or last told.
    var dark = false
    /// Only HTML render rows opt in. MCP apps and file previews keep their own live state.
    var htmlCache: HtmlRenderWebCache?
    var htmlAttachmentId: String? { didSet { if oldValue != htmlAttachmentId { needsLayout = true } } }
    private var loaded = false
    private var pendingHeight: JSONValue?
    private var acceptsMessages = false
    private(set) var loadToken = UUID().uuidString
    private let preview = HtmlRenderPreviewImageView()
    private var captureGeneration = 0
    private var paintReady = false
    private var capturing = false
    private var capturedKey: HtmlRenderWebCache.Key?
    private var displayedKey: HtmlRenderWebCache.Key?

    private var previewKey: HtmlRenderWebCache.Key? {
        guard let htmlAttachmentId, bounds.width > 0, bounds.height > 0 else { return nil }
        return .init(attachmentId: htmlAttachmentId, size: bounds.size, dark: dark, scale: window?.backingScaleFactor ?? 1)
    }

    override var isFlipped: Bool { true }

    var isLive: Bool { webView != nil }
    var hasPreview: Bool { preview.image != nil && preview.superview != nil && !isHiddenOrHasHiddenAncestor }

    /// Creates the web view and loads `page`, unless it already shows it.
    func activate(_ page: Page) {
        if webView != nil, self.page == page { ThreadWebFrameBudget.touch(self); return }
        release()
        self.page = page
        loadToken = UUID().uuidString
        dark = page.dark
        let candidate = page.kind == .agent ? htmlCache?.takeWebView() : nil
        let origin = Self.origin(page.src)
        let spare = candidate?.htmlHostOrigin == origin ? candidate : nil
        // The outgoing iframe can post a resize before WebKit replaces it. Wait for our isolated start
        // signal before accepting page messages through the new controller.
        acceptsMessages = spare == nil
        let config = spare?.configuration ?? WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        let controller = spare?.configuration.userContentController ?? WKUserContentController()
        if page.kind == .agent {
            config.websiteDataStore = ThreadWebFrameBudget.dataStore
            let world = WKContentWorld.world(name: "t3-host")
            controller.add(ThreadWebFrameMessageProxy(self, token: loadToken), contentWorld: world, name: "t3host")
            controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        } else {
            // A file tab gets no bridge at all, and nothing the page stores outlives the tab.
            config.websiteDataStore = .nonPersistent()
        }
        config.userContentController = controller
        let web = spare ?? ThreadWebView(frame: bounds, configuration: config)
        web.frame = bounds
        // The recycled host can still contain the outgoing frame until WebKit runs the replacement script.
        web.isHidden = spare != nil
        web.forwardsScroll = page.kind == .agent
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.onUserActivity = { [weak self] in self?.lastUserActivity = Date() }
        addSubview(web)
        webView = web
        htmlCache?.activated(web)
        needsLayout = true
        if let key = previewKey, htmlCache?.contains(key) == true { layoutSubtreeIfNeeded() }
        hostLoaded = spare != nil
        frameLoads = 0
        shortcutsPosted = false
        if spare != nil {
            let token = loadToken
            web.callAsyncJavaScript(Self.bridgeScript + Self.replaceFrameScript,
                                    arguments: ["src": page.src.absoluteString, "title": page.title, "dark": page.dark, "token": token],
                                    in: nil, in: .world(name: "t3-host")) { [weak self, weak web] result in
                guard case .failure = result, let self, let web, self.webView === web, self.loadToken == token else { return }
                // A cached host whose process was reclaimed starts from its HTML again.
                self.hostLoaded = false
                self.frameLoads = 0
                self.acceptsMessages = true
                self.hostNavigation = web.loadHTMLString(Self.hostPage(page), baseURL: URL(string: "about:blank"))
            }
        } else {
            web.htmlHostOrigin = page.kind == .agent ? origin : nil
            hostNavigation = web.loadHTMLString(Self.hostPage(page), baseURL: URL(string: "about:blank"))
        }
        if page.kind == .agent { ThreadWebFrameBudget.add(self) }
        #if DEBUG
        Self.benchmarkObserver?("activate", page, self, nil)
        #endif
    }

    /// Tears the web view down; its content process goes when no other view uses it.
    func release() {
        let wasLoaded = loaded
        lastUserActivity = .distantPast
        loaded = false
        pendingHeight = nil
        captureGeneration &+= 1
        paintReady = false
        capturing = false
        capturedKey = nil
        displayedKey = nil
        preview.image = nil
        preview.removeFromSuperview()
        acceptsMessages = false
        hostNavigation = nil
        guard let web = webView else { return }
        #if DEBUG
        if let page { Self.benchmarkObserver?("release", page, self, nil) }
        #endif
        web.stopLoading()
        web.navigationDelegate = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.configuration.userContentController.removeAllUserScripts()
        web.onUserActivity = nil
        web.removeFromSuperview()
        webView = nil
        ThreadWebFrameBudget.remove(self)
        htmlCache?.recycle(web, reusable: wasLoaded)
        needsLayout = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let navigation, navigation === hostNavigation else { return }
        loaded = true
        webView.isHidden = false
        flushHeight()
        preparePreview(webView)
    }

    private func preparePreview(_ web: WKWebView) {
        guard htmlCache != nil else { return }
        let token = loadToken, appearance = dark
        web.callAsyncJavaScript("await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return true;",
                                arguments: [:], in: nil, in: .world(name: "t3-host")) { [weak self, weak web] result in
            guard case .success = result, let self, let web, self.webView === web,
                  self.loadToken == token, self.dark == appearance else { return }
            self.paintReady = true
            self.needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        guard let key = previewKey, htmlCache?.isActive == true, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        if displayedKey != key {
            preview.image = nil
            preview.removeFromSuperview()
            displayedKey = nil
            if !paintReady, let image = htmlCache?.image(for: key) {
                displayedKey = key
                preview.image = image
                preview.imageScaling = .scaleAxesIndependently
                preview.frame = bounds
                preview.autoresizingMask = [.width, .height]
                addSubview(preview, positioned: .above, relativeTo: webView)
                #if DEBUG
                Self.benchmarkObserver?("preview", page ?? .init(src: URL(string: "about:blank")!, title: "Cached page", dark: dark), self, nil)
                #endif
            }
        }
        if capturedKey != key { capturePreview() }
    }

    func refreshPreview() {
        capturedKey = nil
        displayedKey = nil
        preview.image = nil
        preview.removeFromSuperview()
        paintReady = false
        if loaded, let webView { preparePreview(webView) }
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refreshPreview() }

    private func capturePreview() {
        guard paintReady, !capturing, window != nil, !isHiddenOrHasHiddenAncestor,
              let web = webView, let cache = htmlCache, let key = previewKey else { return }
        if cache.contains(key) {
            capturedKey = key
            preview.image = nil
            preview.removeFromSuperview()
            return
        }
        capturing = true
        let generation = captureGeneration, cacheGeneration = cache.generation
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        web.takeSnapshot(with: config) { [weak self, weak web, weak cache] image, _ in
            guard let self, let web, self.webView === web, self.captureGeneration == generation else { return }
            self.preview.image = nil
            self.preview.removeFromSuperview()
            self.capturing = false
            guard self.previewKey == key else { self.needsLayout = true; return }
            self.capturedKey = key
            guard let pixels = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            cache?.insert(pixels, for: key, generation: cacheGeneration)
            #if DEBUG
            if let page = self.page {
                Self.benchmarkObserver?("snapshot", page, self, .object(["previewBytes": .number(Double(cache?.cost ?? 0))]))
            }
            #endif
        }
    }

    /// Sees every message posted into a live page. Tests watch the transport with it.
    var onPost: ((JSONValue) -> Void)?

    /// Posts a JSON-RPC message into the framed document's window.
    func post(_ message: JSONValue) {
        guard let webView, let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        onPost?(message)
        webView.callAsyncJavaScript("window.__t3post(message)", arguments: ["message": text], in: nil, in: .world(name: "t3-host"), completionHandler: nil)
    }

    func received(_ body: Any, isMainFrame: Bool, token: String) {
        // Only the host page's isolated bridge speaks here; a framed document never reaches this world.
        guard isMainFrame, webView != nil, token == loadToken else { return }
        // The bridge forwards page messages as strings. This structured signal comes only from our own
        // isolated-world iframe load listener, including a replacement frame in a reused host.
        if (body as? [String: Any])?["t3FrameStarted"] as? String == loadToken {
            acceptsMessages = true
            webView?.isHidden = false
            return
        }
        if (body as? [String: Any])?["t3FrameLoaded"] as? String == loadToken {
            loaded = true
            webView?.isHidden = false
            flushHeight()
            if let webView { preparePreview(webView) }
            return
        }
        guard acceptsMessages, let text = body as? String, let json = try? JSONValue(parsing: Data(text.utf8)) else { return }
        // T3 reports at DOMContentLoaded, on resize and on load (htmlRender.ts:405). While images load,
        // keep its last report without repeatedly resizing and retiling the native timeline.
        if htmlCache != nil, !loaded, HtmlRenderTheme.contentHeight(json) != nil {
            if !shortcutsPosted { shortcutsPosted = true; post(HtmlRenderShortcuts.message()) }
            pendingHeight = json
            return
        }
        deliver(json)
    }

    private func flushHeight() {
        guard let height = pendingHeight else { return }
        pendingHeight = nil
        deliver(height)
    }

    private func deliver(_ json: JSONValue) {
        onMessage?(json)
        #if DEBUG
        if let page { Self.benchmarkObserver?("message", page, self, json) }
        #endif
    }

    /// Whether the reader is using this frame now: it holds focus and they just clicked or typed in it.
    var userIsActive: Bool {
        guard let webView, let responder = window?.firstResponder as? NSView, responder === webView || responder.isDescendant(of: webView) else { return false }
        return Date().timeIntervalSince(lastUserActivity) < 5
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, let page else { decisionHandler(.cancel); return }
        let target: NavigationTarget = action.targetFrame.map { $0.isMainFrame ? .host : .frame } ?? .newWindow
        // `window.open` from a click has no click type of its own; a frame navigation must be a link click.
        let clicked = userIsActive && (target == .newWindow || action.navigationType == .linkActivated)
        let decision = Self.decide(kind: page.kind, target: target, url: action.request.url, src: page.src, hostLoaded: hostLoaded, frameLoads: frameLoads, userClicked: clicked)
        switch target {
        case .host: hostLoaded = hostLoaded || decision == .allow
        case .frame: frameLoads += 1
        case .newWindow: break
        }
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
            if page.kind == .agent, target == .frame, frameLoads > 1 { onNavigatedAway?() }
        case .openExternally(let url):
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
        }
    }

    /// The navigation policy. The host page loads once, from its string. An agent's frame loads its document once;
    /// a second load would let a page T3 never served pose as it. A workspace file's frame may reload its own
    /// document and follow its own fragment links. Anywhere else, a workspace file's link opens in the browser
    /// only when the reader clicked it and it is http or https (DesktopWindow.ts:620-637, `parseSafeExternalUrl`).
    /// Everything else is refused.
    static func decide(kind: Kind, target: NavigationTarget, url: URL?, src: URL, hostLoaded: Bool, frameLoads: Int, userClicked: Bool) -> NavigationDecision {
        var external = NavigationDecision.cancel
        if kind == .workspaceFile, userClicked, let url, SafeExternalURL.isSafe(url) { external = .openExternally(url) }
        switch target {
        case .newWindow:
            return external
        case .host:
            return !hostLoaded && url?.absoluteString == "about:blank" ? .allow : .cancel
        case .frame:
            guard sameDocument(url, src) else { return external }
            return frameLoads == 0 || kind == .workspaceFile ? .allow : .cancel
        }
    }

    static func sameDocument(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.absoluteString.split(separator: "#", maxSplits: 1).first == b.absoluteString.split(separator: "#", maxSplits: 1).first
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        // The content process went away (memory pressure): drop the view; the row makes a new one when shown.
        release()
        onEvicted?()
    }

    // MARK: Host page

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func origin(_ url: URL) -> String {
        url.scheme.map { "\($0)://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")" } ?? "'none'"
    }

    /// A blank page holding only the sandboxed frame. Its policy forbids every load but the frame's origin.
    static func hostPage(_ page: Page) -> String {
        var origin = Self.origin(page.src)
        // A file's link click must reach `decide` to open in the browser; a narrower frame-src would drop it in WebKit
        // first. `decide` still refuses every frame load but the file itself, so the frame never leaves it.
        if page.kind == .workspaceFile { origin += " http: https:" }
        // A file preview sits on white in T3 (`bg-white`, BrowserDocumentFrame.tsx:36) and keeps the page's own scheme.
        let look = page.kind == .workspaceFile ? "background:#fff" : "color-scheme:\(page.dark ? "dark" : "light")"
        let allow = page.allow.isEmpty ? "" : " allow=\"\(escape(page.allow))\""
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; frame-src \(escape(origin))">\
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}\
        iframe{display:block;border:0;width:100%;height:100%;\(look)}</style></head>\
        <body><iframe id="f" title="\(escape(page.title))" sandbox="\(page.kind.sandbox)"\(allow) src="\(escape(page.src.absoluteString))"></iframe></body></html>
        """
    }

    /// Runs in the isolated `t3-host` world: forwards the frame's messages, posts back into the frame.
    static let bridgeScript = """
    (function(){
      if (window.__t3bridge) window.removeEventListener("message", window.__t3bridge);
      window.__t3bridge = function(e){
        var f = document.getElementById("f");
        if (!f) return;
        if (e.source !== f.contentWindow) return;
        try { window.webkit.messageHandlers.t3host.postMessage(JSON.stringify(e.data)); } catch (x) {}
      };
      window.addEventListener("message", window.__t3bridge);
      window.__t3post = function(text){ var f = document.getElementById("f"); if (f && f.contentWindow) f.contentWindow.postMessage(JSON.parse(text), "*"); };
    })();
    """

    /// Replacing the iframe discards its complete browsing context. The host and its strict origin policy stay;
    /// callers reuse this host only for another HTML attachment from that same origin.
    private static let replaceFrameScript = """
    document.getElementById("f")?.remove();
    var f = document.createElement("iframe");
    f.id = "f";
    f.title = title;
    f.setAttribute("sandbox", "allow-scripts allow-forms");
    f.style.colorScheme = dark ? "dark" : "light";
    f.src = src;
    f.addEventListener("load", function(){ if (document.getElementById("f") === f) window.webkit.messageHandlers.t3host.postMessage({t3FrameLoaded:token}); }, {once:true});
    window.webkit.messageHandlers.t3host.postMessage({t3FrameStarted:token});
    document.body.appendChild(f);
    return true;
    """
}

/// Cached pixels never intercept input meant for the live page underneath.
private final class HtmlRenderPreviewImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The web view: wheel events go to the timeline (a framed page fits its content and hides its scrollbar),
/// and clicks and keys mark the reader's activity for link opening.
final class ThreadWebView: WKWebView {
    var htmlHostOrigin: String?
    var htmlUses = 0
    var onUserActivity: (() -> Void)?
    /// A file preview scrolls its own page; a timeline frame hands the wheel to the timeline.
    var forwardsScroll = true
    override func scrollWheel(with event: NSEvent) {
        if forwardsScroll { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
    override func mouseDown(with event: NSEvent) { onUserActivity?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) { onUserActivity?(); super.keyDown(with: event) }
}

/// Holds the frame weakly so the user content controller does not keep it alive.
private final class ThreadWebFrameMessageProxy: NSObject, WKScriptMessageHandler {
    weak var frame: ThreadWebFrameView?
    let token: String
    init(_ frame: ThreadWebFrameView, token: String) { self.frame = frame; self.token = token }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let main = message.frameInfo.isMainFrame
        MainActor.assumeIsolated { frame?.received(body, isMainFrame: main, token: token) }
    }
}

/// At most `limit` inline web views, least recently shown evicted first. Expanded replies share the store
/// without taking an inline slot (HtmlRenderDialog.tsx:40-47 mounts a separate HtmlRenderDocument).
@MainActor
enum ThreadWebFrameBudget {
    static let limit = 3
    /// One non-persistent store while a frame or a shown document's HTML cache lives. Scroll transitions reuse
    /// the cached HTML; hiding the last document and releasing its frames lets the store and network process go.
    static var dataStore: WKWebsiteDataStore {
        if let store { return store }
        let made = WKWebsiteDataStore.nonPersistent()
        store = made
        return made
    }
    private static var store: WKWebsiteDataStore?
    private static var live: [ThreadWebFrameView] = []
    private struct CacheOwner { weak var cache: HtmlRenderWebCache? }
    private static var caches: [CacheOwner] = []

    static func retainCache(_ cache: HtmlRenderWebCache) {
        caches.removeAll { $0.cache == nil || $0.cache === cache }
        caches.append(CacheOwner(cache: cache))
    }

    static func releaseCache(_ cache: HtmlRenderWebCache) {
        caches.removeAll { $0.cache == nil || $0.cache === cache }
        discardUnusedStore()
    }

    private static func discardUnusedStore() {
        caches.removeAll { $0.cache == nil }
        if live.isEmpty && caches.isEmpty { store = nil }
    }

    static func add(_ frame: ThreadWebFrameView) {
        live.removeAll { $0 === frame }
        live.append(frame)
        while count > limit, let oldest = live.first(where: { $0.budgeted }) {
            oldest.release()
            oldest.onEvicted?()
        }
    }

    static func touch(_ frame: ThreadWebFrameView) {
        guard let i = live.firstIndex(where: { $0 === frame }) else { return }
        live.append(live.remove(at: i))
    }

    static func remove(_ frame: ThreadWebFrameView) {
        live.removeAll { $0 === frame }
        // Only an actual release ends the store's lifetime. Moving the first frame to the end of the
        // list in add/touch can briefly empty it while that frame still owns its web view.
        discardUnusedStore()
    }

    /// Force Reload: wipes what live frames stored (cache, cookies, web storage). A store with no frames is gone already.
    static func clearData() {
        for owner in caches { owner.cache?.clear() }
        store?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// For tests and the memory report.
    static var count: Int { live.filter(\.budgeted).count }
}

/// Keyboard focus in a framed page, for the app's shortcut dispatcher.
@MainActor
public enum ThreadWebFrames {
    /// An agent page or file preview has the keyboard, as a focused iframe does.
    public static func holdKeyboard(in window: NSWindow?) -> Bool {
        var view = window?.firstResponder as? NSView
        while let v = view {
            if v is ThreadWebView { return true }
            view = v.superview
        }
        return false
    }
}
