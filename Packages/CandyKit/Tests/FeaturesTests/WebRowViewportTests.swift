import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

/// HTML renders and MCP apps hold a live page only while their row overlaps the viewport: a row in the 400pt
/// overscan keeps its view but drops the web view and bridge, and a URL that resolves after it left can't revive it.
@MainActor
struct WebRowViewportTests {
    /// Hands out the page URL at once, or holds it until `open` when `delayed`. It counts the asks, as the app's
    /// `webAssetURL` remints a URL near expiry on each one.
    @MainActor final class Assets {
        var delayed = false
        var calls = 0
        var waiting: [CheckedContinuation<URL?, Never>] = []
        let url = URL(string: "http://127.0.0.1:47391/page.html")!
        func resolve() async -> URL? {
            calls += 1
            guard delayed else { return url }
            return await withCheckedContinuation { waiting.append($0) }
        }
        func open() { let w = waiting; waiting = []; w.forEach { $0.resume(returning: url) } }
    }

    static func webItem(mcp: Bool) throws -> TimelineItem {
        if mcp {
            let app = try #require(McpAppReference(.object([
                "attachmentId": .string("capture"), "server": .string("Blender sandbox"),
                "tool": .string("capture"), "resourceUri": .string("ui://capture")
            ])))
            let entry = McpAppEntry(app: app, sourceThreadId: ThreadId("sandbox"), itemId: TurnItemId("capture"), revision: "1")
            return TimelineItem(row: TimelineRow(id: "web", createdAt: nil, kind: .mcpApp(entry)))
        }
        return TimelineItem(row: TimelineRow(id: "web", createdAt: nil, kind: .htmlRender(
            HtmlRenderReference(attachmentId: "page", title: "Page", height: 240))))
    }

    static func until(_ done: () -> Bool) async {
        for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A timeline whose first row is the web row, above enough filler to scroll it away.
    static func fixture(mcp: Bool, assets: Assets) throws -> (NSWindow, TimelineView, ThreadViewModel, TimelineRowView, ThreadWebFrameView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 844, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let t = TimelineView(frame: NSRect(x: 0, y: 0, width: 844, height: 600))
        window.contentView = t
        let model = ThreadViewModel()
        model.webAssetURL = { _, _ in await assets.resolve() }
        model.mcpApp = McpAppActions(request: { _, _ in throw McpAppHostBridge.Refusal("offline") }, turnItem: { _, _ in nil }, sendMessage: nil)
        t.context.model = model
        t.setItems([try webItem(mcp: mcp)] + Array(try ThreadTimelineTests.manyItems(copies: 1).prefix(40)))
        t.layoutSubtreeIfNeeded()
        TimelineTilingTests.userScroll(t, to: 0)
        let row = try #require(t.view(forRow: "web"))
        let frame = try #require(row.subviews.compactMap { $0 as? ThreadWebFrameView }.first)
        // Parallel web tests share the process-wide budget, which would evict this frame at random.
        frame.budgeted = false
        return (window, t, model, row, frame)
    }

    /// Scrolls the web row just past the top of the viewport, inside overscan, and checks it is still mounted.
    static func scrollAway(_ t: TimelineView, _ row: TimelineRowView) {
        TimelineTilingTests.userScroll(t, to: row.frame.maxY + 100)
        #expect(t.view(forRow: "web") === row, "the row stays mounted in overscan")
        #expect(!t.scrollView.contentView.bounds.intersects(row.frame))
    }

    @Test(arguments: [false, true])
    func leavingTheViewportReleasesThePageAndReturningReloadsIt(mcp: Bool) async throws {
        let assets = Assets()
        let (window, t, model, row, frame) = try Self.fixture(mcp: mcp, assets: assets)
        defer { row.prepareForReuse(); _ = (window, model) }
        await Self.until { frame.isLive }
        #expect(frame.isLive)
        let height = row.frame.height
        Self.scrollAway(t, row)
        #expect(!frame.isLive)
        #expect(row.frame.height == height)
        TimelineTilingTests.userScroll(t, to: 0)
        await Self.until { frame.isLive }
        #expect(frame.isLive)
        #expect(row.frame.height == height)
        #expect(assets.calls == 2, "re-entry asks for the URL again, since a kept signed URL may have expired")
        row.isHidden = true
        #expect(!frame.isLive, "a hidden row holds no page")
        row.isHidden = false
        await Self.until { frame.isLive }
        #expect(frame.isLive)
    }

    @Test(arguments: [false, true])
    func aURLThatResolvesAfterExitDoesNotRecreateThePage(mcp: Bool) async throws {
        let assets = Assets()
        assets.delayed = true
        let (window, t, model, row, frame) = try Self.fixture(mcp: mcp, assets: assets)
        defer { row.prepareForReuse(); _ = (window, model) }
        await Self.until { !assets.waiting.isEmpty }
        #expect(!assets.waiting.isEmpty)
        Self.scrollAway(t, row)
        assets.open()
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!frame.isLive)
        TimelineTilingTests.userScroll(t, to: 0)
        await Self.until { !assets.waiting.isEmpty }
        assets.open()
        await Self.until { frame.isLive }
        #expect(frame.isLive)
    }

    @Test func aFullscreenAppOutlivesItsRowLeavingTheViewport() async throws {
        let assets = Assets()
        let (window, t, model, row, frame) = try Self.fixture(mcp: true, assets: assets)
        defer { row.prepareForReuse(); _ = (window, model) }
        await Self.until { frame.isLive }
        let app = try #require(row as? McpAppRowView)
        #expect(app.setDisplayMode("fullscreen", userInitiated: true) == "fullscreen")
        let web = frame.webView
        Self.scrollAway(t, row)
        #expect(frame.isLive && frame.webView === web, "the visible full screen app stays")
        #expect(app.setDisplayMode("inline") == "inline")
        #expect(!frame.isLive, "closing full screen off the viewport releases the app")
    }

    /// An app with a read in flight leaves and comes back before its old bridge finished tearing down. The old
    /// bridge's late answer must not reach the new page, which may reuse the same request id.
    @Test func anOldBridgeCannotAnswerIntoTheNextPage() async throws {
        let assets = Assets()
        let (window, t, model, row, frame) = try Self.fixture(mcp: true, assets: assets)
        defer { row.prepareForReuse(); _ = (window, model) }
        var held: [CheckedContinuation<JSONValue, Never>] = []
        model.mcpApp = McpAppActions(request: { method, _ in
            guard method == "mcpApps.readResource" else { throw McpAppHostBridge.Refusal("offline") }
            return await withCheckedContinuation { held.append($0) }
        }, turnItem: { _, _ in nil }, sendMessage: nil)
        await Self.until { frame.isLive }
        func send(_ text: String) throws { frame.onMessage?(try JSONValue(parsing: Data(text.utf8))) }
        try send(#"{"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{}}"#)
        try send(#"{"jsonrpc":"2.0","method":"ui/notifications/initialized"}"#)
        try send(#"{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"ui://capture/data"}}"#)
        await Self.until { !held.isEmpty }
        #expect(held.count == 1)
        Self.scrollAway(t, row)
        TimelineTilingTests.userScroll(t, to: 0)
        await Self.until { frame.isLive }
        #expect(frame.isLive)
        var posted: [JSONValue] = []
        frame.onPost = { posted.append($0) }
        held.forEach { $0.resume(returning: .object(["contents": .array([])])) }
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!posted.contains { $0["id"] == .number(5) }, "the old bridge's answer stays out of the new page")
    }
}
