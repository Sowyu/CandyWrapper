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
///
/// A workspace HTML file (`Kind.workspaceFile`, BrowserDocumentFrame.tsx:53-59) uses the same host page with T3's
/// file flags, `allow-scripts allow-forms allow-popups allow-downloads`, no bridge, its own data store and no budget.
@MainActor
final class ThreadWebFrameView: NSView, WKNavigationDelegate {
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
    private(set) var webView: ThreadWebView?
    private var page: Page?
    private var hostLoaded = false
    private var frameLoads = 0
    /// The last time the reader clicked or typed in the frame: links open only right after that.
    private(set) var lastUserActivity = Date.distantPast
    /// An HTML render was told which app shortcuts it may pass on.
    var shortcutsPosted = false

    override var isFlipped: Bool { true }

    var isLive: Bool { webView != nil }

    /// Creates the web view and loads `page`, unless it already shows it.
    func activate(_ page: Page) {
        if webView != nil, self.page == page { ThreadWebFrameBudget.touch(self); return }
        release()
        self.page = page
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        let controller = WKUserContentController()
        if page.kind == .agent {
            config.websiteDataStore = ThreadWebFrameBudget.dataStore
            let world = WKContentWorld.world(name: "t3-host")
            controller.add(ThreadWebFrameMessageProxy(self), contentWorld: world, name: "t3host")
            controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        } else {
            // A file tab gets no bridge at all, and nothing the page stores outlives the tab.
            config.websiteDataStore = .nonPersistent()
        }
        config.userContentController = controller
        let web = ThreadWebView(frame: bounds, configuration: config)
        web.forwardsScroll = page.kind == .agent
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.onUserActivity = { [weak self] in self?.lastUserActivity = Date() }
        addSubview(web)
        webView = web
        hostLoaded = false
        frameLoads = 0
        shortcutsPosted = false
        web.loadHTMLString(Self.hostPage(page), baseURL: URL(string: "about:blank"))
        if page.kind == .agent { ThreadWebFrameBudget.add(self) }
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
        guard let page else { decisionHandler(.cancel); return }
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
        var origin = page.src.scheme.map { "\($0)://\(page.src.host ?? "")\(page.src.port.map { ":\($0)" } ?? "")" } ?? "'none'"
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

    /// Force Reload: wipes what live frames stored (cache, cookies, web storage). A store with no frames is gone already.
    static func clearData() {
        store?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// For tests and the memory report.
    static var count: Int { live.count }
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
