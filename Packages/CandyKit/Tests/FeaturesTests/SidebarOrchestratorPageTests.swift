import AppKit
import DesignSystem
import Testing
import T3Protocol
@testable import Features

/// The Conductor's pane opens like a thread: the sidebar keeps its list, buttons and footer with no Back, its own row
/// shows it's open, and no thread row is active meanwhile. Pull Requests and Usage keep T3's Back footer.
@MainActor @Suite(.serialized) struct SidebarOrchestratorPageTests {
    @Test func theConductorLeavesTheSidebarAsItIs() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntime.input
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let content = SidebarContentView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 900)
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("t1", "Fix the build", project: "p1", kind: .done, minutesAgo: 2),
        ]), animated: false)
        content.orchestrator = OrchestratorSidebarInfo(name: "Conductor", machine: "miniko", machineKind: "mac-mini", bot: .orchestrator,
                                                       needsYou: 0, working: false, started: true, isOpen: true)
        content.state.activeThreadId = ThreadId("t1")
        content.showsOtherPage = true
        content.layoutSubtreeIfNeeded()
        #expect(content.state.activeThreadId == nil)
        // Something setting the route thread meanwhile doesn't light a row either.
        content.state.activeThreadId = ThreadId("t1")
        #expect(content.state.activeThreadId == nil)
        #expect(content.backButton.isHidden)
        #expect(!content.navRows[0].isHidden)
        // Back on a thread, its row lights again.
        content.showsOtherPage = false
        content.state.activeThreadId = ThreadId("t1")
        #expect(content.state.activeThreadId == ThreadId("t1"))
        // A T3 utility page still shows Back.
        content.isOnUtilityPage = true
        content.layoutSubtreeIfNeeded()
        #expect(!content.backButton.isHidden)
        window.contentView = nil
    }
}
