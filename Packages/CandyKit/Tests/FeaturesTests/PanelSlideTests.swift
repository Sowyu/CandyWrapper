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
