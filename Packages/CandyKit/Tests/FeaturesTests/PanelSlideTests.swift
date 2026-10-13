import AppKit
import QuartzCore
import Testing
@testable import DesignSystem
@testable import Features

/// The right panel and the terminal drawer slide on `PanelSlide` like the sidebar: the chat column reflows
/// every frame, a reversal starts where the panel is, and the last frame is the resting layout.
@MainActor
struct PanelSlideTests {
    private func makePanel() -> (NSWindow, ThreadPanelView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
        panel.referenceViewportWidth = 1400
        window.contentView = panel
        panel.layoutSubtreeIfNeeded()
        return (window, panel)
    }

    /// T3 keeps the details card's inline and popover visibility apart: a narrow chat shows it as a popover that
    /// starts closed, and widening the window again shows the inline card as the user left it.
    @Test func detailsPopoverIsSeparateFromTheInlineCard() {
        let (window, panel) = makePanel()
        _ = window
        panel.setDetailsInlineOpen(true)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.detailsInline && panel.detailsOpen && panel.lazyDetailsCard.loaded?.isHidden == false)
        panel.setFrameSize(NSSize(width: 800, height: 800))
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.detailsInline && !panel.detailsOpen && panel.lazyDetailsCard.loaded?.isHidden == true)
        panel.setDetailsOpen(true)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.detailsOpen && panel.lazyDetailsCard.loaded?.isHidden == false)
        panel.closeDetailsPopover()
        #expect(!panel.detailsOpen)
        panel.setFrameSize(NSSize(width: 1400, height: 800))
        panel.layoutSubtreeIfNeeded()
        #expect(panel.detailsInline && panel.detailsOpen)
    }

    /// Hidden panels hold nothing until they first show; a closed one stays built and hidden.
    @Test func hiddenPanelsAreBuiltOnFirstShow() {
        let (window, panel) = makePanel()
        _ = window
        #expect(panel.lazyDetailsCard.loaded == nil && panel.lazyTerminalDrawer.loaded == nil)
        #expect(panel.lazyStashMenu.loaded == nil && panel.lazyQuestionPanel.loaded == nil)
        panel.setDetailsOpen(true)
        panel.setTerminal(open: true, height: 200)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.lazyDetailsCard.loaded?.superview === panel && panel.lazyTerminalDrawer.loaded?.isHidden == false)
        panel.setDetailsOpen(false)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.lazyDetailsCard.loaded?.isHidden == true)
    }

    @Test func rightPanelSlidesAndLandsOnItsRestingFrame() {
        let previous = SettingsPanelMotion.durationMs
        defer { SettingsPanelMotion.durationMs = previous }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // The resting frames, without motion.
        SettingsPanelMotion.durationMs = 0
        let (_, still) = makePanel()
        still.mutatePanel { $0.open(.diff); return [] }
        #expect(!still.panelSlide.isRunning)
        let restPanel = still.rightPanel.frame, restHeader = still.header.frame

        SettingsPanelMotion.durationMs = 200
        let (window, panel) = makePanel()
        _ = window
        panel.mutatePanel { $0.open(.diff); return [] }
        #expect(panel.panelSlide.isRunning && panel.rightPanel.frame.width == restPanel.width)
        panel.panelSlide.step(at: CACurrentMediaTime() + 0.05)
        let edge = panel.rightPanel.frame.minX
        #expect(edge > restPanel.minX && edge < 1400)
        // The chat column ends where the panel starts.
        #expect(panel.header.frame.width == edge)
        // Closing mid-slide turns back from where it is.
        panel.mutatePanel { $0.isOpen = false; return [] }
        #expect(panel.panelSlide.isRunning && panel.panelSlide.target == 0)
        #expect(panel.header.frame.width == edge)
        panel.panelSlide.step(at: CACurrentMediaTime() + 10)
        #expect(!panel.panelSlide.isRunning && panel.header.frame.width == 1400)
        // Open again and let it finish: exactly the resting layout.
        panel.mutatePanel { $0.open(.diff); return [] }
        panel.panelSlide.step(at: CACurrentMediaTime() + 10)
        #expect(!panel.panelSlide.isRunning)
        #expect(panel.rightPanel.frame == restPanel && panel.header.frame == restHeader)
    }

    @Test func terminalSlidesUnderTheChatColumn() {
        let previous = SettingsPanelMotion.durationMs
        defer { SettingsPanelMotion.durationMs = previous }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        SettingsPanelMotion.durationMs = 200
        let (window, panel) = makePanel()
        _ = window
        panel.setTerminal(open: true, height: 280)
        #expect(panel.terminalSlide.isRunning)
        panel.terminalSlide.step(at: CACurrentMediaTime() + 0.05)
        // The drawer keeps its height, so its terminal keeps its grid, and its top edge moves up.
        #expect(panel.terminalDrawer.frame.height == 280)
        #expect(panel.terminalDrawer.frame.minY > 520 && panel.terminalDrawer.frame.minY < 800)
        panel.terminalSlide.step(at: CACurrentMediaTime() + 10)
        #expect(!panel.terminalSlide.isRunning && panel.terminalDrawer.frame == NSRect(x: 0, y: 520, width: 1400, height: 280))
        // A resize drag moves at once.
        panel.setTerminal(open: true, height: 300)
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.terminalSlide.isRunning && panel.terminalDrawer.frame.minY == 500)
    }
}
