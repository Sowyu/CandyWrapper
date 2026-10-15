import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct SidebarActionWiringTests {
    func host(_ content: SidebarContentView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
        content.layoutSubtreeIfNeeded()
        return window
    }

    @Test func rowButtonsReachTheAppActions() {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        var calls: [String] = []
        // Set after the rows exist: rows read the current actions when they fire.
        content.setSnapshot(SidebarPreview.richSnapshot(), animated: false)
        content.list.layoutSubtreeIfNeeded()
        content.actions.settle = { calls.append("settle \($0.rawValue)") }
        content.actions.unpin = { calls.append("unpin \($0.rawValue)") }
        // r1 is pinned: its pin glyph is the unpin button.
        let card = content.list.rowView("thread:r1") as? SidebarCardRowView
        #expect(card?.pin.isHidden == false)
        card?.pin.performAction()
        card?.settleButton.performAction()
        #expect(calls == ["unpin r1", "settle r1"])
        window.contentView = nil
    }

    /// A woken row keeps its Woke pill beside the hover actions, never under them, and the pill dismisses the wake.
    @Test func wokePillSitsBesideTheActionsAndDismisses() throws {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        var calls: [String] = []
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("w1", "Add a mode", project: "p1", kind: .read, minutesAgo: 400,
                                  extra: ["snoozedUntil": SidebarPreview.iso(10), "snoozedAt": SidebarPreview.iso(60)]),
        ]), animated: false)
        content.list.layoutSubtreeIfNeeded()
        content.actions.acknowledgeWake = { calls.append("wake \($0.rawValue)") }
        let card = try #require(content.list.rowView("thread:w1") as? SidebarCardRowView)
        #expect(card.row?.topStatus == .woke && !card.wokeButton.isHidden)
        var hot = card.state
        hot.hovered = true
        card.previewState(hot)
        card.layoutSubtreeIfNeeded()
        let actions = card.snoozeButton.isHidden ? card.settleButton.frame : card.snoozeButton.frame
        #expect(card.wokeButton.frame.width > 20 && card.wokeButton.frame.maxX <= actions.minX)
        card.wokeButton.performAction()
        #expect(calls == ["wake w1"])
        window.contentView = nil
    }

    @Test func undoNoticeAndUtilityFooter() {
        let content = SidebarContentView()
        let window = host(content)
        var undone = 0
        content.actions.undo = { undone += 1 }
        content.undoNoticeText = "Settled 1 thread,"
        content.layoutSubtreeIfNeeded()
        #expect(!content.undoNotice.isHidden)
        #expect(content.undoNotice.frame.height == 30)
        #expect(content.undoNotice.frame.maxY == content.settingsButton.frame.minY - 8)
        #expect(content.scrollArea.frame.maxY <= content.undoNotice.frame.minY)
        content.undoNotice.button.performAction()
        #expect(undone == 1)
        content.undoNoticeText = nil
        content.isOnUtilityPage = true
        content.layoutSubtreeIfNeeded()
        #expect(content.undoNotice.isHidden && content.settingsButton.isHidden && !content.backButton.isHidden)
        window.contentView = nil
    }
}
