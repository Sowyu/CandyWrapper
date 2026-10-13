import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Glass Native's thread (docs/glass-native.md phase 3): the native row metrics, a style switch that keeps the
/// tiling contract, and a working pill that holds nothing while hidden. The classic style's pixels are the
/// fidelity suite's job.
@MainActor
struct NativeTimelineTests {
    @Test func theColumnIsAtMost960AndKeeps20OnEachSide() {
        let wide = NativeTimeline.lane(width: 1400)
        #expect(wide.width == 960)
        #expect(wide.x == 220)
        let narrow = NativeTimeline.lane(width: 700)
        #expect(narrow.x == 20)
        #expect(narrow.width == 660)
    }

    /// A user message and a work row, both on screen.
    static func sample() throws -> [TimelineItem] {
        let all = try ThreadTimelineTests.manyItems(copies: 1)
        let user = try #require(all.first { if case .message(let m, _, _, _, _, _) = $0.row.kind { m.role == .user && m.text.count > 300 } else { false } })
        let work = try #require(all.first { if case .work(let e, false, _) = $0.row.kind { e.count == 1 } else { false } })
        return [user, work]
    }

    static func timeline(width: CGFloat, style: TimelineStyle) -> TimelineView {
        let t = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 728))
        t.style = style
        t.layoutSubtreeIfNeeded()
        return t
    }

    @Test func nativeRowsUseTheMobileMetrics() throws {
        let items = try Self.sample()
        let t = Self.timeline(width: 1400, style: .native)
        t.setItems(items)
        t.layoutSubtreeIfNeeded()
        #expect(t.laneFrame.width == 960)
        let user = try #require(t.view(forRow: items[0].id) as? UserMessageRowView)
        // A long message fills the bubble's cap: 85% of the column.
        #expect(user.bubbleWidth(forWidth: 960) == NativeTimeline.maxBubble(960))
        #expect(user.frame.width == 960)
        let work = try #require(t.view(forRow: items[1].id) as? WorkRowView)
        let line = try #require(work.lines.first)
        #expect(line.frame.height == NativeTimeline.workLine)
        #expect(line.native)
        #expect(t.layoutProblems().isEmpty)
    }

    @Test func classicRowsKeepTheirMetrics() throws {
        let items = try Self.sample()
        let t = Self.timeline(width: 1400, style: .classic)
        t.setItems(items)
        t.layoutSubtreeIfNeeded()
        let user = try #require(t.view(forRow: items[0].id) as? UserMessageRowView)
        #expect(user.bubbleWidth(forWidth: t.laneFrame.width) == t.laneFrame.width * 0.8)
        let work = try #require(t.view(forRow: items[1].id) as? WorkRowView)
        #expect(work.lines.first?.frame.height == 24)
        #expect(work.lines.first?.native == false)
    }

    /// Switching the style at runtime measures every row again and comes back to the same layout.
    @Test func switchingTheStyleRoundTrips() throws {
        let items = Array(try ThreadTimelineTests.manyItems(copies: 1).prefix(120))
        let t = Self.timeline(width: 1000, style: .classic)
        t.setItems(items)
        t.layoutSubtreeIfNeeded()
        t.scrollToEnd(animated: false)
        t.layoutSubtreeIfNeeded()
        let classicHeight = t.documentHeight
        t.style = .native
        t.layoutSubtreeIfNeeded()
        #expect(t.layoutProblems().isEmpty)
        t.style = .classic
        t.layoutSubtreeIfNeeded()
        t.scrollToEnd(animated: false)
        t.layoutSubtreeIfNeeded()
        #expect(t.layoutProblems().isEmpty)
        #expect(abs(t.documentHeight - classicHeight) < 1)
    }

    @Test func theWorkingRowHandsOverToThePill() {
        let t = Self.timeline(width: 1000, style: .native)
        var changes = 0
        t.onWorkingChange = { changes += 1 }
        let since = T3Timestamp("2026-10-13T10:00:00.000Z")
        let working = TimelineItem(row: TimelineRow(id: "working-indicator-row", createdAt: since, kind: .working(compacting: false)))
        t.setItems([working])
        t.layoutSubtreeIfNeeded()
        #expect(t.working == TimelineWorking(sinceMs: since.epochMs, compacting: false))
        #expect(changes == 1)
        // The row itself keeps no height in the native style.
        #expect(t.view(forRow: working.id)?.frame.height ?? 0 == 0)
        t.setItems([])
        #expect(t.working == nil)
        #expect(changes == 2)
    }

    @Test func theWorkingPillHoldsNothingWhenHidden() {
        let pill = NativeWorkingPillView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        #expect(pill.isHidden)
        #expect(!pill.holdsContent)
        pill.state = .working(sinceMs: Int64(Date().timeIntervalSince1970 * 1000) - 3_000)
        #expect(!pill.isHidden)
        #expect(pill.holdsContent)
        #expect(pill.holdsTick)
        pill.state = .syncing
        #expect(!pill.holdsTick)
        pill.state = nil
        #expect(pill.isHidden)
        #expect(!pill.holdsContent)
        #expect(!pill.holdsTick)
    }

    @Test func thePanelTurnsTheNativeThreadOnAndOff() {
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        #expect(panel.timeline.style == .classic)
        panel.hidesCustomChrome = true
        #expect(panel.timeline.style == .native)
        #expect(panel.approvalPanel.nativeCard)
        panel.hidesCustomChrome = false
        #expect(panel.timeline.style == .classic)
        #expect(!panel.approvalPanel.nativeCard)
        #expect(!panel.subviews.contains { $0 is NativeWorkingPillView })
    }
}
