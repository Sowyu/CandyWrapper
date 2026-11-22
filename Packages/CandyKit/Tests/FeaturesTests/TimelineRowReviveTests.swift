import AppKit
import Testing
import T3Protocol
import T3Store
@testable import Features

/// A message scrolled out of the overscan and back gets the view that showed it, with its Markdown layout, instead of
/// a pooled view configured and laid out again (3 to 10 ms a 6 KB reply, `scroll_long_back_and_forth`).
@MainActor @Suite struct TimelineRowReviveTests {
    private func item(_ id: String, _ text: String) -> TimelineItem {
        let message = ChatMessage(id: MessageId(id), role: .assistant, text: text, createdAt: "2026-10-14T00:00:00Z")
        return TimelineItem(row: TimelineRow(id: id, createdAt: nil, kind: .message(
            message, projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false,
            assistantCopyStreaming: false, turnDiffSummary: nil)))
    }

    private func timeline() -> TimelineView {
        let filler = String(repeating: "Filler paragraph with enough words to take a few lines of the lane. ", count: 8)
        let items = (0..<40).map { item("m\($0)", "Reply \($0).\n\n" + filler + "\n\n" + filler) }
        let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        timeline.layoutSubtreeIfNeeded()
        timeline.setItems(items)
        timeline.scroll(by: -timeline.documentHeight)
        timeline.layoutSubtreeIfNeeded()
        return timeline
    }

    /// Scrolls `m0` out of the overscan and back to the top.
    private func away(_ timeline: TimelineView, between: () -> Void = {}) {
        var steps = 0
        while timeline.view(forRow: "m0") != nil, steps < 40 { timeline.scroll(by: 300); steps += 1 }
        #expect(timeline.view(forRow: "m0") == nil)
        between()
        timeline.scroll(by: -timeline.documentHeight)
        timeline.layoutSubtreeIfNeeded()
    }

    @Test func aMessageScrolledBackGetsItsOwnViewUnconfigured() throws {
        let timeline = timeline()
        let first = try #require(timeline.view(forRow: "m0"))
        away(timeline)
        let back = try #require(timeline.view(forRow: "m0"))
        #expect(back === first)
        let configures = timeline.configureCount
        // A second trip configures nothing at all: every row that comes back finds its view.
        away(timeline)
        #expect(timeline.configureCount == configures)
        #expect(timeline.view(forRow: "m0") === first)
        #expect(back.height(forWidth: back.frame.width) == back.frame.height)
        #expect(timeline.layoutProblems().isEmpty)
    }

    /// Rows configured again while a view sat in the pool (a parse landing, a setting): the view comes back configured.
    @Test func aPassThatReconfiguresTheVisibleRowsReachesPooledViewsWhenTheyReturn() throws {
        let timeline = timeline()
        away(timeline)
        var configures = timeline.configureCount
        away(timeline) { timeline.context.onDocumentReady?("m0") }
        #expect(timeline.configureCount > configures)
        configures = timeline.configureCount
        away(timeline)
        #expect(timeline.configureCount == configures)
    }

    /// The pool keeps at most `spares` message views a kind beyond the ones on screen.
    @Test func thePoolStaysBounded() {
        let timeline = timeline()
        for _ in 0..<3 {
            timeline.scroll(by: timeline.documentHeight)
            timeline.layoutSubtreeIfNeeded()
            timeline.scroll(by: -timeline.documentHeight)
            timeline.layoutSubtreeIfNeeded()
        }
        let shown = (0..<40).filter { timeline.view(forRow: "m\($0)") != nil }.count
        #expect(timeline.createdRowViews <= shown + TimelineView.spares + 2)
        #expect(timeline.layoutProblems().isEmpty)
    }

    /// Rows that host a page or hold a signed URL never come back from the pool unconfigured: their return builds the
    /// page and mints the URL again (`WebRowViewportTests.scrollingReleasesAnHtmlRendersPageAndReturningReloadsIt`).
    @Test func webRowsConfigureOnEveryReturn() throws {
        let filler = String(repeating: "Filler paragraph with enough words to take a few lines of the lane. ", count: 8)
        for mcp in [false, true] {
            let web = try WebFrameSuites.WebRowViewportTests.webItem(mcp: mcp)
            let items = [web] + (0..<40).map { item("m\($0)", "Reply \($0).\n\n" + filler + "\n\n" + filler) }
            let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            timeline.layoutSubtreeIfNeeded()
            timeline.setItems(items)
            timeline.scroll(by: -timeline.documentHeight)
            timeline.layoutSubtreeIfNeeded()
            func trip() -> Int {
                let before = timeline.configureCount
                var steps = 0
                while timeline.view(forRow: "web") != nil, steps < 40 { timeline.scroll(by: 300); steps += 1 }
                #expect(timeline.view(forRow: "web") == nil)
                timeline.scroll(by: -timeline.documentHeight)
                timeline.layoutSubtreeIfNeeded()
                #expect(timeline.view(forRow: "web") != nil)
                return timeline.configureCount - before
            }
            _ = trip()
            // The messages come back unconfigured by now; the web row configures each time.
            #expect(trip() == 1, "mcp \(mcp)")
            #expect(trip() == 1, "mcp \(mcp)")
        }
    }

    /// Hiding the timeline and switching threads drop the spares and every parked view's claim on its message.
    @Test(arguments: ["hide", "thread"]) func hideAndThreadChangeDropTheSpares(_ path: String) throws {
        let timeline = timeline()
        let items = timeline.items
        /// Down the whole thread 300 pt a step and back to the top: the configures that took.
        func trip() -> Int {
            let before = timeline.configureCount
            for _ in 0..<200 where timeline.viewportMinY < timeline.documentHeight - 700 { timeline.scroll(by: 300) }
            for _ in 0..<200 where timeline.viewportMinY > 0 { timeline.scroll(by: -300) }
            timeline.layoutSubtreeIfNeeded()
            return timeline.configureCount - before
        }
        _ = trip()
        let pooled = timeline.pooledCount(.assistant)
        #expect(pooled >= TimelineView.spares, "stepping through the thread made spares")
        // Reading back near the top revives what it left.
        let near = timeline.configureCount
        timeline.scroll(by: 1_200); timeline.scroll(by: -1_200)
        #expect(timeline.configureCount == near)
        if path == "hide" {
            timeline.isHidden = true
            #expect(timeline.pooledCount(.assistant) < pooled, "the spares went")
            timeline.isHidden = false
        } else {
            timeline.setItems([item("other", "Another thread.")], change: .thread)
            timeline.layoutSubtreeIfNeeded()
            #expect(timeline.pooledCount(.assistant) < pooled, "the spares went")
            // Back on the first thread, every message it shows is configured, as on a fresh view.
            let before = timeline.configureCount
            timeline.setItems(items, change: .thread)
            timeline.layoutSubtreeIfNeeded()
            timeline.scroll(by: -timeline.documentHeight)
            timeline.layoutSubtreeIfNeeded()
            let shown = (0..<40).filter { timeline.view(forRow: "m\($0)") != nil }.count
            #expect(timeline.configureCount - before >= shown)
            #expect(timeline.layoutProblems().isEmpty)
            return
        }
        // A message that comes back is configured, as on a fresh view.
        let before = timeline.configureCount
        timeline.scroll(by: 1_200); timeline.scroll(by: -1_200)
        #expect(timeline.configureCount > before)
        #expect(timeline.layoutProblems().isEmpty)
    }
}
