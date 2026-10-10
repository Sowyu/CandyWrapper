import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// previewStateStore.ts, rightPanelStore.ts browser surfaces, useDiscoveredLocalServers.ts and
/// browserHistoryStore.ts.
struct PreviewStateTests {
    func snap(_ tab: String, _ at: String, url: String? = nil, reveal: Bool? = nil) -> PreviewSessionSnapshot {
        PreviewSessionSnapshot(threadId: "t", tabId: tab, navStatus: url.map { .success(url: $0, title: "") } ?? .idle,
                               reveal: reveal, updatedAt: at)
    }

    @Test func listAndEvents() {
        var s = ThreadPreviewState()
        s.reconcile(PreviewListResult(sessions: [snap("a", "1"), snap("b", "2")], serverEpoch: "e1", revision: 3))
        #expect(s.listLoaded && s.activeTabId == "b")
        // An older revision is ignored; an opened tab becomes active.
        s.apply(PreviewEvent(type: .closed, threadId: "t", tabId: "b", serverEpoch: "e1", revision: 2))
        #expect(s.sessions["b"] != nil)
        s.apply(PreviewEvent(type: .opened, threadId: "t", tabId: "c", serverEpoch: "e1", revision: 4, snapshot: snap("c", "3")))
        #expect(s.activeTabId == "c")
        s.apply(PreviewEvent(type: .failed, threadId: "t", tabId: "c", createdAt: "4", serverEpoch: "e1", revision: 5,
                             url: "http://x/", title: "", code: -102, description: "ERR_CONNECTION_REFUSED"))
        #expect(s.sessions["c"]?.navStatus.isFailed == true)
        s.apply(PreviewEvent(type: .closed, threadId: "t", tabId: "c", serverEpoch: "e1", revision: 6))
        #expect(s.sessions["c"] == nil && s.activeTabId == "b")
        // Another server epoch asks for the list again.
        let sameServer = s.apply(PreviewEvent(type: .closed, threadId: "t", tabId: "a", serverEpoch: "e2", revision: 1))
        #expect(!sameServer)
    }

    @Test func optimisticClose() {
        var s = ThreadPreviewState()
        s.reconcile(PreviewListResult(sessions: [snap("a", "1")], serverEpoch: "e", revision: 1))
        s.beginClose("a")
        #expect(s.sessions.isEmpty)
        // A stale list must not bring the closing tab back.
        s.reconcile(PreviewListResult(sessions: [snap("a", "1")], serverEpoch: "e", revision: 1))
        #expect(s.sessions.isEmpty)
        s.cancelClose(snap("a", "1"), tabId: "a")
        #expect(s.activeTabId == "a")
    }

    @Test func updateKeepsActive() {
        var s = ThreadPreviewState()
        s.applyOpened(snap("a", "1"))
        s.applyOpened(snap("b", "2"))
        s.update(snap("a", "3", url: "http://a/"))
        #expect(s.activeTabId == "b" && s.sessions["a"]?.navStatus.url == "http://a/")
        s.update(snap("a", "0"))
        #expect(s.sessions["a"]?.navStatus.url == "http://a/")
        var hidden = s
        hidden.applyOpened(snap("h", "4", reveal: false))
        #expect(hidden.panelTabIds.hidden == ["h"])
    }

    @Test func panelSurfaces() {
        var p = RightPanelState()
        p.open(.browser)
        #expect(p.activeSurfaceId == "browser:new" && p.isOpen)
        p.openBrowser("t1")
        #expect(p.surfaces.map(\.id) == ["browser:t1"])
        p.upsert(.diff)
        p.reconcileBrowser(tabIds: ["t1", "t2", "h"], hidden: ["h"])
        #expect(p.surfaces.map(\.id) == ["diff", "browser:t1", "browser:t2"])
        p.activate("browser:t2")
        p.reconcileBrowser(tabIds: ["t1"], hidden: [])
        #expect(p.surfaces.map(\.id) == ["diff", "browser:t1"] && p.activeSurfaceId == "browser:t1")
        #expect(RightPanelSurface.browser(tabId: "x").title == "Browser")
        var closed = ClosedPanelTabs()
        closed.remember(.browser(tabId: "t1"), threadKey: "k", browserURL: "http://a/")
        #expect(closed.entries.first?.browserURL == "http://a/")
    }

    @Test func discovery() {
        let bounded = LocalServerDiscovery.boundConfiguredUrls(["http://localhost:3000", "http://localhost:3000#x", "https://example.com",
                                                                " http://localhost:1", "ftp://localhost:2", "http://127.0.0.1:4000/app"])
        #expect(bounded == ["http://localhost:3000", "http://127.0.0.1:4000/app"])
        let servers = [DiscoveredLocalServer(host: "localhost", port: 5000, url: "http://localhost:5000"),
                       DiscoveredLocalServer(host: "127.0.0.1", port: 4000, url: "http://127.0.0.1:4000", processName: "node"),
                       DiscoveredLocalServer(host: "0.0.0.0", port: 3000, url: "http://localhost:3000")]
        let merged = LocalServerDiscovery.merge(scanner: servers, configuredUrls: ["http://localhost:4000/app"], configuredUrlProbing: false)
        #expect(merged.map(\.server.port) == [4000, 3000, 5000])
        #expect(merged[0].source == .configured && merged[0].requestedUrl == "http://localhost:4000/app")
        #expect(merged[0].title == "node" && merged[1].title == "Listening" && merged[1].detail == "0.0.0.0:3000")
        let probing = LocalServerDiscovery.merge(scanner: servers, configuredUrls: ["http://localhost:4000/app"], configuredUrlProbing: nil)
        #expect(probing[0].requestedUrl == "http://127.0.0.1:4000")
        var withTerminal = servers[0]
        withTerminal.terminal = .init(threadId: "t", terminalId: "x")
        #expect(LocalServerDiscovery.forThread([withTerminal, servers[1]], threadId: "t").count == 1)
    }

    @Test func history() {
        var h = BrowserHistory()
        h.recordVisit("p", url: "http://localhost:3000/a", at: 1)
        h.recordVisit("p", url: "127.0.0.1:3000/a", at: 2)
        // Loopback hosts are one place; the stable local URL is kept.
        #expect(h.entries("p").count == 1 && h.entries("p")[0].lastVisitedAt == 2)
        h.recordVisit("p", url: "https://user:pw@example.com/x", at: 3)
        #expect(h.entries("p")[0].url == "https://example.com/x")
        h.setTitle("p", url: "http://localhost:3000/a/", title: " Home ")
        #expect(h.entries("p")[1].title == "Home")
        h.setTitle("p", url: "https://other.com", title: "Nope")
        #expect(h.entries("p").count == 2)
        h.remove("p", url: "https://example.com/x")
        #expect(h.entries("p").count == 1)
        for i in 0..<60 { h.recordVisit("p", url: "https://e.com/\(i)", at: Double(10 + i)) }
        #expect(h.entries("p").count == BrowserHistory.maxEntriesPerProject)
        for i in 0..<25 { h.recordVisit("q\(i)", url: "https://e.com", at: Double(100 + i)) }
        #expect(h.byProjectKey.count == BrowserHistory.maxProjects && h.byProjectKey["p"] == nil)
        #expect(BrowserHistory.label("http://localhost:3000/") == "localhost:3000")
        #expect(BrowserHistory.label("https://a.com/b?c=1#d") == "a.com/b?c=1#d")
    }
}
