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
}
