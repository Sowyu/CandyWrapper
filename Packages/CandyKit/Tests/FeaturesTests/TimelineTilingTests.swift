import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The tiling contract under the live app's traffic (duplicated and misplaced rows on a long live
/// thread, 2026-10-10): a long thread opened from its tail, user scrolls toward the top that page
/// in older history through `onNearTop`, a running turn whose tail rows grow and change kind under
/// the same id, and width changes. After every step `layoutProblems()` must be empty.
@MainActor
struct TimelineTilingTests {
    /// A work entry and a grown copy of an assistant message, borrowed from the fixtures.
    static func liveParts(_ all: [TimelineItem]) throws -> (WorkLogEntry, ChatMessage) {
        var entry: WorkLogEntry?, message: ChatMessage?
        for item in all {
            if entry == nil, case .work(let entries, _, _) = item.row.kind { entry = entries.first }
            if message == nil, case .message(let m, _, _, _, _, _) = item.row.kind, m.role == .assistant { message = m }
        }
        return (try #require(entry), try #require(message))
    }

    /// The live tail at step `n`: the working header, then the activity row, which is `thinking`
    /// on even steps and `workLive` on odd ones under the same id, then a streaming answer that
    /// grows every step.
    static func tail(_ n: Int, entry: WorkLogEntry, message: ChatMessage) -> [TimelineItem] {
        var rows = [TimelineRow(id: "working-indicator-row", createdAt: nil, kind: .working(compacting: nil))]
        rows.append(n % 2 == 0
            ? TimelineRow(id: "live-activity-row", createdAt: nil, kind: .thinking(groupId: nil, expanded: nil, compacting: false))
            : TimelineRow(id: "live-activity-row", createdAt: nil, kind: .workLive(
                entry: entry, groupedEntries: [entry], groupId: "g", expanded: false, active: true, thought: nil)))
        var m = message
        m.id = "live-answer"
        m.streaming = true
        m.text = Array(repeating: "Streaming answer paragraph \(n) grows as the turn runs.", count: 1 + n).joined(separator: "\n\n")
        rows.append(TimelineRow(id: "live-answer", createdAt: nil, kind: .message(
            m, projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false, assistantCopyStreaming: true, turnDiffSummary: nil)))
        return rows.map { TimelineItem(row: $0) }
    }

    static func check(_ t: TimelineView, _ step: String) {
        let problems = t.layoutProblems()
        #expect(problems.isEmpty, "\(step): \(problems.prefix(6).joined(separator: "; "))")
    }

    /// The user drags the scroller: the clip view moves without `adjusting`, so `didScroll` runs.
    static func userScroll(_ t: TimelineView, to y: CGFloat) {
        let clip = t.scrollView.contentView
        let maxY = max(0, (t.scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        t.scrollView.reflectScrolledClipView(clip)
    }

    /// The rows run on under the thread header: with a top clearance the first row starts that much lower and the
    /// contract holds. The top fade eases out from the panel's top with no solid part.
    @Test func headerClearanceKeepsTheFirstRowClear() throws {
        let all = Array(try ThreadTimelineTests.manyItems(copies: 1).prefix(40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 844, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let t = TimelineView(frame: NSRect(x: 0, y: 0, width: 844, height: 600))
        window.contentView = t
        t.setItems(all)
        t.layoutSubtreeIfNeeded()
        Self.userScroll(t, to: 0)
        let top = try #require(t.view(forRow: all[0].id)).frame.minY
        t.topClearance = 52
        t.layoutSubtreeIfNeeded()
        Self.userScroll(t, to: 0)
        Self.check(t, "clearance")
        #expect(try #require(t.view(forRow: all[0].id)).frame.minY == top + 52)
        #expect(ThreadPanelView.topFade(0) == 0.85 && ThreadPanelView.topFade(1) == 0)
        #expect(ThreadPanelView.topFade(0.3) > ThreadPanelView.topFade(0.6))
    }

    @Test func longLiveThreadKeepsTheContract() throws {
        var all = try ThreadTimelineTests.manyItems(copies: 6)
        #expect(all.count >= 500)
        all = Array(all.prefix(520))
        let (entry, message) = try Self.liveParts(all)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 844, height: 728), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let t = TimelineView(frame: NSRect(x: 0, y: 0, width: 844, height: 728))
        window.contentView = t
        t.bottomInset = 172
        t.layoutSubtreeIfNeeded()

        // The bounded snapshot: the newest 150 rows plus the live tail.
        var loaded = all.count - 150
        var step = 0
        func apply() { t.setItems(Array(all[loaded...]) + Self.tail(step, entry: entry, message: message)) }
        t.onNearTop = {
            // A history page: 100 older rows arrive while the user is still scrolling.
            guard loaded > 0 else { return }
            loaded = max(0, loaded - 100)
            apply()
        }
        apply()
        Self.check(t, "open")

        for round in 0..<14 {
            step += 1
            // Jump most of the way up, or to the top, which pages in history.
            Self.userScroll(t, to: round % 2 == 0 ? 100 : t.scrollView.contentView.bounds.minY * 0.35)
            Self.check(t, "round \(round) scrolled up")
            // The live tail streams while the user reads old history.
            apply()
            Self.check(t, "round \(round) live update")
            if round % 3 == 0 {
                window.setContentSize(NSSize(width: [600, 900, 844][round % 9 / 3], height: 728))
                t.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
                t.layoutSubtreeIfNeeded()
                Self.check(t, "round \(round) width \(t.frame.width)")
            }
            Self.userScroll(t, to: t.scrollView.contentView.bounds.minY + 1300)
            Self.check(t, "round \(round) scrolled down")
        }
        #expect(loaded == 0, "history paged in to the first row")

        // The end: the last row sits fully above the composer.
        t.scrollToEnd(animated: false)
        t.layoutSubtreeIfNeeded()
        Self.check(t, "end")
        let viewport = t.scrollView.contentView.bounds
        let last = try #require(t.view(forRow: Self.tail(step, entry: entry, message: message).last!.id))
        #expect(last.frame.maxY <= viewport.maxY - t.bottomInset + 0.5)

        // Scroll the whole thread top to bottom in 500pt steps, as the user's sweep did.
        Self.userScroll(t, to: 0)
        var y: CGFloat = 0
        while y < t.documentHeight {
            Self.userScroll(t, to: y)
            Self.check(t, "sweep \(y)")
            y += 500
        }
    }

    @Test func upwardWheelPagesWithinOneFoldedRow() throws {
        let all = try ThreadTimelineTests.manyItems(copies: 1)
        let (_, message) = try Self.liveParts(all)
        let t = TimelineView(frame: NSRect(x: 0, y: 0, width: 844, height: 728))
        let window = NSWindow(contentRect: t.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = t
        var answer = message
        answer.text = "The completed answer."
        t.setItems([
            TimelineItem(row: TimelineRow(id: "folded-run", createdAt: nil,
                kind: .turnFold(runId: "same-run", label: "Worked for 1s", expanded: false))),
            TimelineItem(row: TimelineRow(id: "answer", createdAt: nil, kind: .message(answer,
                projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false,
                assistantCopyStreaming: false, turnDiffSummary: nil))),
        ])
        t.layoutSubtreeIfNeeded()
        #expect(!t.overflowsComposerViewport)
        t.historyCursor = "page-1"
        var requests = 0
        t.onNearTop = { requests += 1 }
        func wheel(_ delta: Int32) throws {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
            t.scrollView.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        }
        try wheel(-60)
        #expect(requests == 0, "downward scrolling does not ask for older history")
        try wheel(60)
        #expect(requests == 1, "upward scrolling works even without a bounds change")
        try wheel(60)
        #expect(requests == 1, "one outstanding page per cursor")
        t.historyCursor = "page-2"
        try wheel(60)
        #expect(requests == 2, "the same folded row can receive another page")
        t.historyCursor = "page-2"
        try wheel(60)
        #expect(requests == 2, "unchanged updates do not rearm demand")
    }

    /// The user's sharper repro: when a turn finishes, its live rows (working header, interim
    /// answers, the activity line, tool groups) give way to a fold and the final answer under new
    /// ids. None of the live views may stay on screen, at the end or scrolled away.
    @Test func finishedTurnLeavesNoLiveRows() throws {
        let all = try ThreadTimelineTests.manyItems(copies: 2)
        let (entry, message) = try Self.liveParts(all)
        let history = Array(all.prefix(120))
        func msg(_ id: String, _ text: String) -> TimelineItem {
            var m = message
            m.id = MessageId(id)
            m.text = text
            return TimelineItem(row: TimelineRow(id: id, createdAt: nil, kind: .message(
                m, projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false, assistantCopyStreaming: false, turnDiffSummary: nil)))
        }
        func work(_ id: String) -> TimelineItem {
            TimelineItem(row: TimelineRow(id: id, createdAt: nil, kind: .work(groupedEntries: [entry, entry], isExpandedToolGroup: false, displayLabel: "Ran 2 commands")))
        }
        let live: [TimelineItem] = [
            TimelineItem(row: TimelineRow(id: "working-indicator-row", createdAt: nil, kind: .working(compacting: nil))),
            msg("interim-1", "Looking at the seam.\n\nIt is real."), work("tools-1"),
            msg("interim-2", "Fixing the spill-over myself.\n\nOne line clips the grid."), work("tools-2"),
            TimelineItem(row: TimelineRow(id: "live-activity-row", createdAt: nil, kind: .workLive(
                entry: entry, groupedEntries: [entry], groupId: "g", expanded: false, active: true, thought: nil))),
        ]
        let settled: [TimelineItem] = [
            TimelineItem(row: TimelineRow(id: "turn-fold:run-9", createdAt: nil, kind: .turnFold(runId: "run-9", label: "Worked for 7m 39s", expanded: false))),
            msg("final", Array(repeating: "The final answer, with more lines than the interim ones.", count: 8).joined(separator: "\n\n")),
        ]
        for scrolledAway in [false, true] {
            let t = ThreadTimelineTests.timeline(history + live)
            if scrolledAway { Self.userScroll(t, to: t.documentHeight / 2) }
            let liveViews = live.compactMap { t.view(forRow: $0.id) }
            if !scrolledAway { #expect(liveViews.count == live.count) }
            t.setItems(history + settled)
            Self.check(t, "finished, scrolled away \(scrolledAway)")
            for view in liveViews { #expect(view.isHidden || settled.contains { $0.id == view.item?.id }, "live row \(view.item?.id ?? "") still drawn") }
            t.scrollToEnd(animated: false)
            Self.check(t, "finished, at end after \(scrolledAway)")
        }
    }

    /// The case behind the doubled rows: an id that changes kind keeps its old view class, which
    /// then can't configure itself, keeps its old text, and goes into the wrong pool.
    @Test func idChangingKindGetsANewView() throws {
        let all = try ThreadTimelineTests.manyItems(copies: 1)
        let (entry, message) = try Self.liveParts(all)
        let t = ThreadTimelineTests.timeline(Array(all.prefix(20)) + Self.tail(0, entry: entry, message: message))
        let thinking = try #require(t.view(forRow: "live-activity-row"))
        t.setItems(Array(all.prefix(20)) + Self.tail(1, entry: entry, message: message))
        let live = try #require(t.view(forRow: "live-activity-row"))
        #expect(live !== thinking)
        #expect(live is WorkLiveRowView)
        #expect(thinking.isHidden)
        Self.check(t, "after kind change")
    }
}
