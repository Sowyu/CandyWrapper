import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct SidebarModelTests {
    let nowMs = TimestampFormat.nowMs(SidebarPreview.referenceNow)

    @Test func referenceRowsMatchTheCapture() {
        var state = SidebarListState(activeThreadId: SidebarPreview.referenceActiveThread)
        state.capabilities = .init(threadSettlement: true, threadSnooze: true)
        let items = SidebarListBuilder.items(snapshot: SidebarPreview.referenceSnapshot(), state: state, nowMs: nowMs)
        let rows = items.compactMap { if case .row(let r) = $0 { r } else { nil } }
        #expect(rows.map(\.statusLabel) == ["Done", "Done", "Done", nil, nil, nil, "Input", "Approval"])
        #expect(rows[3].timeLabel == "16m" && rows[4].timeLabel == "17m" && rows[5].timeLabel == "18m")
        #expect(rows[4].isActive && rows[3].recedes && !rows[0].recedes)
        #expect(rows.allSatisfy { $0.projectLabel == "demo-repo" && $0.variant == .card })
        // The settled header is always there, collapsed and counted.
        #expect(items.last == .shelfHeader(.settled, label: "Settled (0)", expanded: false))
    }

    @Test func richShelvesAndLabels() {
        var state = SidebarListState()
        let snap = SidebarPreview.richSnapshot()
        var items = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs)
        let keys = items.map(\.key)
        #expect(keys.prefix(2) == ["thread:r1", "thread:r2"]) // pinned first
        #expect(items.contains(.shelfHeader(.snoozed, label: "Snoozed (1)", expanded: false)))
        #expect(items.contains(.shelfHeader(.settled, label: "Settled (2)", expanded: false)))
        #expect(!keys.contains("thread:r10"))
        state.settledExpanded = true
        state.snoozedExpanded = true
        items = SidebarListBuilder.items(snapshot: snap, state: state, nowMs: nowMs)
        #expect(items.contains(.shelfHeader(.settled, label: "Settled", expanded: true)))
        let snoozed = items.compactMap { if case .row(let r) = $0, r.section == .snoozed { r } else { nil } }
        #expect(snoozed.first?.snoozeLabel == "2h" && snoozed.first?.variant == .slim)
    }

    @Test func monogramIdentityFollowsT3() {
        #expect(ProjectMonogramView.identity("demo-repo").monogram == "DR")
        #expect(ProjectMonogramView.identity("t3code").monogram == "T3")
        #expect(ProjectMonogramView.identity("candywrapper").monogram == "CR")
    }

    @Test func nextLabelChangeAimsAtTheNextStep() {
        let items = SidebarListBuilder.items(snapshot: SidebarPreview.referenceSnapshot(), state: SidebarListState(), nowMs: nowMs)
        let rows = items.compactMap { if case .row(let r) = $0 { r } else { nil } }
        // "16m" was 16 minutes ago exactly, so it turns into "17m" a minute from now.
        let next = SidebarListBuilder.nextLabelChange(rows.filter { $0.timeLabel == "16m" }, nowMs: nowMs)
        #expect(next == nowMs + 60_000)
        // Status rows show no time, so nothing can change.
        #expect(SidebarListBuilder.nextLabelChange(rows.filter { $0.statusLabel == "Input" }, nowMs: nowMs) == nil)
        #expect(SidebarListBuilder.snoozeWakeLabel(wakeMs: nowMs + 90 * 60_000, nowMs: nowMs) == "2h")
        #expect(SidebarListBuilder.snoozeWakeLabel(wakeMs: nowMs + 1, nowMs: nowMs) == "1m")
    }

    @Test func transcriptReplays() throws {
        let snap = try #require(try SidebarPreview.replayedSnapshot())
        let items = SidebarListBuilder.items(snapshot: snap, state: SidebarListState(), nowMs: nowMs)
        #expect(items.contains { if case .row = $0 { true } else { false } })
    }
}

@MainActor
struct SidebarListTests {
    func makeSnapshot(count: Int) -> ShellSnapshot {
        let threads = (0..<count).map {
            SidebarPreview.thread("n\($0)", "Thread \($0)", project: "p", kind: .read, minutesAgo: Double($0 * 3 + 2))
        }
        return SidebarPreview.snapshot(projects: [SidebarPreview.project("p", "demo-repo")], threads: threads)
    }

    func host(_ content: SidebarContentView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
        content.layoutSubtreeIfNeeded()
        content.list.layoutSubtreeIfNeeded()
        return window
    }

    @Test func virtualizesAndRecycles() {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        content.setSnapshot(makeSnapshot(count: 500), animated: false)
        content.list.layoutSubtreeIfNeeded()
        // 640pt of viewport plus 2 x 160pt overscan holds about 12 cards of 83pt, not 500.
        #expect(content.list.liveViewCount < 20)
        let made = content.list.createdRowViews
        content.scrollArea.scroll(to: NSPoint(x: 0, y: 20_000))
        content.list.layoutSubtreeIfNeeded()
        #expect(content.list.liveViewCount < 20)
        #expect(content.list.createdRowViews <= made + 2) // scrolled-out rows came back from the pool
        window.contentView = nil
    }

    @Test func updatesTouchOnlyChangedRows() {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        var snap = makeSnapshot(count: 50)
        content.setSnapshot(snap, animated: false)
        content.list.layoutSubtreeIfNeeded()
        let before = content.list.configureCount
        snap.threads[0].title = "Renamed"
        content.setSnapshot(snap, animated: false)
        #expect(content.list.configureCount == before + 1)
        window.contentView = nil
    }

    @Test func keyboardMovesFocus() {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        content.setSnapshot(makeSnapshot(count: 5), animated: false)
        var opened: ThreadId?
        content.actions.openThread = { opened = $0 }
        content.list.focus(index: 0)
        content.list.moveFocus(1)
        #expect(content.list.focusedKey == "thread:n1")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        content.list.keyDown(with: enter)
        #expect(opened == ThreadId("n1"))
        window.contentView = nil
    }

    @Test func noTimerWithoutAVisibleWindow() {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        content.setSnapshot(makeSnapshot(count: 5), animated: false)
        #expect(content.pendingLabelRefresh == nil)
    }
}
