import AppKit
import Testing
import WebKit
@testable import Features

/// The sandbox and navigation policy of `ThreadWebFrameView`, for agent renders and workspace HTML files.
@MainActor
struct WebFrameSandboxTests {
    typealias F = ThreadWebFrameView
    let src = URL(string: "http://127.0.0.1:47391/api/assets/abc/page.html?sig=1")!

    func decide(_ kind: F.Kind, _ target: F.NavigationTarget, _ url: String, hostLoaded: Bool = true, frameLoads: Int = 1, clicked: Bool = false) -> F.NavigationDecision {
        F.decide(kind: kind, target: target, url: URL(string: url), src: src, hostLoaded: hostLoaded, frameLoads: frameLoads, userClicked: clicked)
    }

    @Test func workspaceFileHostPageUsesT3FileFlags() {
        let html = F.hostPage(.init(src: src, title: "page.html", dark: true, kind: .workspaceFile))
        #expect(html.contains(#"sandbox="allow-scripts allow-forms allow-popups allow-downloads""#))
        #expect(!html.contains("allow-same-origin") && !html.contains("allow-top-navigation"))
        // http and https so a clicked link reaches `decide`; file:, data: and app schemes stay out.
        #expect(html.contains("default-src 'none'; style-src 'unsafe-inline'; frame-src http://127.0.0.1:47391 http: https:\""))
        #expect(html.contains("background:#fff"))
        let agent = F.hostPage(.init(src: src, title: "r", dark: true))
        #expect(agent.contains(#"sandbox="allow-scripts allow-forms""#))
        #expect(agent.contains("frame-src http://127.0.0.1:47391\""))
    }

    @Test func hostLoadsOnceFromItsString() {
        for kind in [F.Kind.agent, .workspaceFile] {
            #expect(decide(kind, .host, "about:blank", hostLoaded: false) == .allow)
            #expect(decide(kind, .host, "about:blank", hostLoaded: true) == .cancel)
            #expect(decide(kind, .host, "https://example.com/", hostLoaded: false, clicked: true) == .cancel)
            #expect(decide(kind, .host, "file:///etc/hosts", hostLoaded: false) == .cancel)
        }
    }

    @Test func workspaceFrameStaysOnItsDocument() {
        #expect(decide(.workspaceFile, .frame, src.absoluteString, frameLoads: 0) == .allow)
        #expect(decide(.workspaceFile, .frame, src.absoluteString + "#section", frameLoads: 1) == .allow)
        // Script navigations go nowhere, whatever the scheme.
        #expect(decide(.workspaceFile, .frame, "file:///etc/hosts") == .cancel)
        #expect(decide(.workspaceFile, .frame, "https://example.com/") == .cancel)
        #expect(decide(.workspaceFile, .frame, "http://127.0.0.1:47391/api/other") == .cancel)
    }

    @Test func clickedWebLinksOpenExternallyOnly() {
        let web = URL(string: "https://example.com/a")!
        #expect(decide(.workspaceFile, .frame, web.absoluteString, clicked: true) == .openExternally(web))
        #expect(decide(.workspaceFile, .newWindow, web.absoluteString, clicked: true) == .openExternally(web))
        #expect(decide(.workspaceFile, .newWindow, web.absoluteString, clicked: false) == .cancel)
        for bad in ["file:///etc/hosts", "candywrapper://open", "javascript:alert(1)", "data:text/html,hi", "mailto:a@b.c"] {
            #expect(decide(.workspaceFile, .frame, bad, clicked: true) == .cancel)
            #expect(decide(.workspaceFile, .newWindow, bad, clicked: true) == .cancel)
        }
    }

    @Test func agentFramesKeepTheirOneLoad() {
        #expect(decide(.agent, .frame, src.absoluteString, frameLoads: 0) == .allow)
        #expect(decide(.agent, .frame, src.absoluteString, frameLoads: 1) == .cancel)
        #expect(decide(.agent, .frame, "https://example.com/", clicked: true) == .cancel)
        #expect(decide(.agent, .newWindow, "https://example.com/", clicked: true) == .cancel)
    }

    @Test func workspaceFileGetsNoBridgeAndNoBudget() throws {
        let before = ThreadWebFrameBudget.count
        let frame = F(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        frame.activate(.init(src: src, title: "page.html", dark: false, kind: .workspaceFile))
        let web = try #require(frame.webView)
        #expect(web.configuration.userContentController.userScripts.isEmpty)
        #expect(!web.configuration.websiteDataStore.isPersistent)
        #expect(!web.forwardsScroll)
        #expect(ThreadWebFrameBudget.count == before)
        frame.release()
        #expect(frame.webView == nil)
    }

    /// The full screen dialog keeps the bridge but takes no budget slot, so it never blanks a render on screen.
    @Test func unbudgetedAgentFrameKeepsItsBridge() throws {
        let before = ThreadWebFrameBudget.count
        let frame = F(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        frame.budgeted = false
        frame.activate(.init(src: src, title: "reply", dark: false))
        let web = try #require(frame.webView)
        #expect(!web.configuration.userContentController.userScripts.isEmpty)
        #expect(ThreadWebFrameBudget.count == before)
        frame.release()
    }
}
