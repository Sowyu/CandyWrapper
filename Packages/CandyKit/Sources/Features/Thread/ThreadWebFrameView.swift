import AppKit
import DesignSystem
import T3Protocol
import T3Store
import WebKit

/// A sandboxed agent document in the timeline, the way T3 frames one (BrowserDocumentFrame.tsx `HtmlRenderDocument`,
/// McpAppFrame.tsx): an `<iframe sandbox="allow-scripts allow-forms">` (never `allow-same-origin`) inside a blank
/// host page whose own policy allows nothing but that frame. The bridge lives in an isolated script world the
/// page cannot reach, forwards only messages from the frame's own window, and posts back into it. The document
/// never navigates: the host page loads once and the frame once; anything after that is refused.
///
/// The web view exists only while `activate` holds it. `ThreadWebFrameBudget` keeps at most a few alive across
/// the app; the timeline releases a row's view when the row scrolls away or the thread closes.
@MainActor
final class ThreadWebFrameView: NSView, WKNavigationDelegate {
    struct Page: Equatable {
        var src: URL
        var title: String
        /// The iframe `allow` attribute (an MCP App's permissions).
        var allow: String = ""
        var dark: Bool
    }

    /// A message the framed document posted.
    var onMessage: ((JSONValue) -> Void)?
    /// The document tried to load a second time (an MCP App left its page).
    var onNavigatedAway: (() -> Void)?
    /// The budget took the web view back.
    var onEvicted: (() -> Void)?
    private(set) var webView: ThreadWebView?
    private var page: Page?
    private var hostLoaded = false
    private var frameLoads = 0
    /// The last time the reader clicked or typed in the frame: links open only right after that.
    private(set) var lastUserActivity = Date.distantPast

    override var isFlipped: Bool { true }

    var isLive: Bool { webView != nil }

    /// Creates the web view and loads `page`, unless it already shows it.
    func activate(_ page: Page) {
        if webView != nil, self.page == page { ThreadWebFrameBudget.touch(self); return }
        release()
        self.page = page
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ThreadWebFrameBudget.dataStore
        config.suppressesIncrementalRendering = false
        let controller = WKUserContentController()
        let world = WKContentWorld.world(name: "t3-host")
        controller.add(ThreadWebFrameMessageProxy(self), contentWorld: world, name: "t3host")
        controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        config.userContentController = controller
        let web = ThreadWebView(frame: bounds, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.onUserActivity = { [weak self] in self?.lastUserActivity = Date() }
        addSubview(web)
        webView = web
        hostLoaded = false
        frameLoads = 0
        web.loadHTMLString(Self.hostPage(page), baseURL: URL(string: "about:blank"))
        ThreadWebFrameBudget.add(self)
    }

    /// Tears the web view down; its content process goes when no other view uses it.
    func release() {
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        webView = nil
        ThreadWebFrameBudget.remove(self)
    }

    /// Posts a JSON-RPC message into the framed document's window.
    func post(_ message: JSONValue) {
        guard let webView, let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        webView.callAsyncJavaScript("window.__t3post(message)", arguments: ["message": text], in: nil, in: .world(name: "t3-host"), completionHandler: nil)
    }

    fileprivate func received(_ body: Any, isMainFrame: Bool) {
        // Only the host page's isolated bridge speaks here; a framed document never reaches this world.
        guard isMainFrame, let text = body as? String, let json = try? JSONValue(parsing: Data(text.utf8)) else { return }
        onMessage?(json)
    }

    /// Whether the reader is using this frame now: it holds focus and they just clicked or typed in it.
    var userIsActive: Bool {
        guard let webView, let responder = window?.firstResponder as? NSView, responder === webView || responder.isDescendant(of: webView) else { return false }
        return Date().timeIntervalSince(lastUserActivity) < 5
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let main = action.targetFrame?.isMainFrame ?? false
        if action.targetFrame == nil { decisionHandler(.cancel); return }
        if main {
            // The host page loads once, from its string.
            let ok = !hostLoaded && action.request.url?.absoluteString == "about:blank"
            hostLoaded = hostLoaded || ok
            decisionHandler(ok ? .allow : .cancel)
            return
        }
        // The frame loads its document once; a second load would let a page T3 never served pose as it.
        frameLoads += 1
        if frameLoads == 1, let src = page?.src, Self.sameDocument(action.request.url, src) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if frameLoads > 1 { onNavigatedAway?() }
        }
    }

    static func sameDocument(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.absoluteString.split(separator: "#", maxSplits: 1).first == b.absoluteString.split(separator: "#", maxSplits: 1).first
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The content process went away (memory pressure): drop the view; the row makes a new one when shown.
        release()
        onEvicted?()
    }

    // MARK: Host page

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    /// A blank page holding only the sandboxed frame. Its policy forbids every load but the frame's origin.
    static func hostPage(_ page: Page) -> String {
        let origin = page.src.scheme.map { "\($0)://\(page.src.host ?? "")\(page.src.port.map { ":\($0)" } ?? "")" } ?? "'none'"
        let scheme = page.dark ? "dark" : "light"
        let allow = page.allow.isEmpty ? "" : " allow=\"\(escape(page.allow))\""
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; frame-src \(escape(origin))">\
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}\
        iframe{display:block;border:0;width:100%;height:100%;color-scheme:\(scheme)}</style></head>\
        <body><iframe id="f" title="\(escape(page.title))" sandbox="allow-scripts allow-forms"\(allow) src="\(escape(page.src.absoluteString))"></iframe></body></html>
        """
    }

    /// Runs in the isolated `t3-host` world: forwards the frame's messages, posts back into the frame.
    static let bridgeScript = """
    (function(){
      var f = document.getElementById("f");
      if (!f) return;
      window.addEventListener("message", function(e){
        if (e.source !== f.contentWindow) return;
        try { window.webkit.messageHandlers.t3host.postMessage(JSON.stringify(e.data)); } catch (x) {}
      });
      window.__t3post = function(text){ if (f.contentWindow) f.contentWindow.postMessage(JSON.parse(text), "*"); };
    })();
    """
}

/// The web view: wheel events go to the timeline (a framed page fits its content and hides its scrollbar),
/// and clicks and keys mark the reader's activity for link opening.
final class ThreadWebView: WKWebView {
    var onUserActivity: (() -> Void)?
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func mouseDown(with event: NSEvent) { onUserActivity?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) { onUserActivity?(); super.keyDown(with: event) }
}

/// Holds the frame weakly so the user content controller does not keep it alive.
private final class ThreadWebFrameMessageProxy: NSObject, WKScriptMessageHandler {
    weak var frame: ThreadWebFrameView?
    init(_ frame: ThreadWebFrameView) { self.frame = frame }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let main = message.frameInfo.isMainFrame
        MainActor.assumeIsolated { frame?.received(body, isMainFrame: main) }
    }
}

/// At most `limit` live web views across the app, least recently shown evicted first.
@MainActor
enum ThreadWebFrameBudget {
    static let limit = 3
    /// One non-persistent store while any frame lives: nothing a page stores outlives it, the frames share one
    /// network process, and the last frame's release lets that process go.
    static var dataStore: WKWebsiteDataStore {
        if let store { return store }
        let made = WKWebsiteDataStore.nonPersistent()
        store = made
        return made
    }
    private static var store: WKWebsiteDataStore?
    private static var live: [ThreadWebFrameView] = [] { didSet { if live.isEmpty { store = nil } } }

    static func add(_ frame: ThreadWebFrameView) {
        live.removeAll { $0 === frame }
        live.append(frame)
        while live.count > limit {
            let oldest = live.removeFirst()
            oldest.release()
            oldest.onEvicted?()
        }
    }

    static func touch(_ frame: ThreadWebFrameView) {
        guard let i = live.firstIndex(where: { $0 === frame }) else { return }
        live.append(live.remove(at: i))
    }

    static func remove(_ frame: ThreadWebFrameView) { live.removeAll { $0 === frame } }

    /// For tests and the memory report.
    static var count: Int { live.count }
}
