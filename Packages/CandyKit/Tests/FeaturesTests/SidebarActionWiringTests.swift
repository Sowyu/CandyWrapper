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
