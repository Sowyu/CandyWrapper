import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

extension WebFrameSuites {
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
            // A host that never resolves: nothing here needs the page to load, and no test reaches a real server.
            let url = URL(string: "http://page.invalid/page.html")!
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

        /// Waits for something that will happen, such as a page mounting; never for something that must not.
        static func until(_ done: () -> Bool) async {
            _ = await eventually { done() }
        }

        /// The row's pending URL lookup.
        static func loading(_ row: TimelineRowView) -> Task<Void, Never>? {
            (row as? HtmlRenderRowView)?.loading ?? (row as? McpAppRowView)?.loading
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
            row.layoutSubtreeIfNeeded()
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

        /// Offscreen pages release WebKit even inside overscan; returning reloads without losing the row's height.
        @Test func scrollingReleasesAnHtmlRendersPageAndReturningReloadsIt() async throws {
            let assets = Assets()
            let (window, t, model, row, frame) = try Self.fixture(mcp: false, assets: assets)
            defer { (t.view(forRow: "web") ?? row).prepareForReuse(); t.context.releasePages(); _ = (window, model) }
            await Self.until { frame.isLive }
            let web = try #require(frame.webView)
            let height = row.frame.height
            Self.scrollAway(t, row)
            #expect(!frame.isLive, "overscan keeps only the native row")
            #expect(row.frame.height == height)
            TimelineTilingTests.userScroll(t, to: 0)
            await Self.until { frame.isLive }
            #expect(frame.webView !== web)
            #expect(row.frame.height == height)
            #expect(assets.calls == 2)
            TimelineTilingTests.userScroll(t, to: row.frame.maxY + 3000)
            #expect(t.view(forRow: "web") == nil)
            #expect(!frame.isLive)
            TimelineTilingTests.userScroll(t, to: 0)
            let back = try #require(t.view(forRow: "web") as? HtmlRenderRowView)
            await Self.until { back.frameView.isLive }
            #expect(back.frame.height == height)
            #expect(assets.calls == 3, "each return remints the signed URL")
            t.isHidden = true
            #expect(!back.frameView.isLive, "a hidden timeline holds no page")
            #expect(!t.context.htmlCache.isActive)
        }

        /// The page reports its height at one width; a row recycled and shown again has it before any page loads.
        @Test func aReportedHeightOutlivesTheRowsView() async throws {
            let assets = Assets()
            let (window, t, model, row, frame) = try Self.fixture(mcp: false, assets: assets)
            defer { (t.view(forRow: "web") ?? row).prepareForReuse(); t.context.releasePages(); _ = (window, model) }
            frame.onMessage?(.object(["jsonrpc": .string("2.0"), "method": .string("ui/notifications/size-changed"), "params": .object(["height": .number(150)])]))
            // The fixture feeds the timeline directly, so it hands the model's updated row on itself.
            let updated = model.item(try Self.webItem(mcp: false).row)
            #expect(updated.ui.htmlHeights.height(width: Double(frame.frame.width)) == 150)
            t.setItems([updated] + Array(try ThreadTimelineTests.manyItems(copies: 1).prefix(40)))
            t.layoutSubtreeIfNeeded()
            let reported = try #require(t.view(forRow: "web")).frame.height
            #expect(reported == 158, "the page's 150 plus the row's 8 under it")
            TimelineTilingTests.userScroll(t, to: row.frame.maxY + 3000)
            t.context.releasePages()
            TimelineTilingTests.userScroll(t, to: 0)
            let back = try #require(t.view(forRow: "web"))
            #expect(back.frame.height == reported)
        }

        @Test func leavingTheViewportReleasesAnAppAndReturningReloadsIt() async throws {
            let mcp = true
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
            let lookup = try #require(Self.loading(row))
            Self.scrollAway(t, row)
            assets.open()
            // The lookup has run to its end with the URL in hand: it had its one chance to mount the page.
            await lookup.value
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
            let app = try #require(row as? McpAppRowView)
            let old = try #require(app.bridge)
            Self.scrollAway(t, row)
            TimelineTilingTests.userScroll(t, to: 0)
            await Self.until { frame.isLive }
            #expect(frame.isLive)
            var posted: [JSONValue] = []
            frame.onPost = { posted.append($0) }
            held.forEach { $0.resume(returning: .object(["contents": .array([])])) }
            // The old bridge answers in the same main actor turn that clears its pending count, so once that count
            // is zero its answer went wherever it was going to go.
            await Self.until { old.pending == 0 }
            #expect(old.pending == 0)
            #expect(!posted.contains { $0["id"] == .number(5) }, "the old bridge's answer stays out of the new page")
        }
    }
}
