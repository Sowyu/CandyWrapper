import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The sidebar wakes only while some visible label can change (idle cost stays at zero). The clock
/// is armed by a row's "2m" label and must be dropped once no label needs it.
@MainActor
struct SidebarLabelClockIdleTests {
    func hosted() -> (NSWindow, SidebarContentView) {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
        content.layoutSubtreeIfNeeded()
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("t1", "Recent", project: "p1", kind: .read, minutesAgo: 2),
        ]), animated: false)
        return (window, content)
    }

    @Test func clockStopsWhenTheLastTimedRowGoes() {
        let (window, content) = hosted()
        defer { window.contentView = nil }
        #expect(content.pendingLabelRefresh != nil)
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: []), animated: false)
        #expect(content.pendingLabelRefresh == nil)
    }

    @Test func clockStopsWhenTheSidebarLeavesItsWindow() {
        let (window, content) = hosted()
        #expect(content.pendingLabelRefresh != nil)
        window.contentView = nil
        #expect(content.window == nil)
        #expect(content.pendingLabelRefresh == nil)
    }
}
