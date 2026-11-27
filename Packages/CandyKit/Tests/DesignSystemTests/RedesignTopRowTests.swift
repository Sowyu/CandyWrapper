import AppKit
import Testing
@testable import DesignSystem

/// Redesign's window top row, after Capy's: the sidebar toggle, back and forward on one row on the traffic lights'
/// centre line, and with the sidebar hidden the breadcrumb starts after them.
@MainActor
struct RedesignTopRowTests {
    @Test(arguments: [false, true]) func historyButtonsShareTheLightsRowWithTheSidebarHidden(inset: Bool) {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = true; input.ditherDark = true; input.insetPanel = inset
        ThemeRuntime.apply(input)
        let shell = SidebarLayoutView(defaults: UserDefaults(suiteName: "cw.top-row.\(UUID().uuidString)")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        window.contentView = shell
        shell.setOpen(false, slides: false)
        shell.viewDidChangeEffectiveAppearance()
        shell.layoutSubtreeIfNeeded()
        let row = [shell.collapsedTrigger, shell.backButton, shell.forwardButton]
        #expect(row.allSatisfy { !$0.isHidden })
        // One centre line, the traffic lights'.
        #expect(row.allSatisfy { $0.frame.midY == SidebarMetrics.topbarHeight / 2 })
        // Left to right, apart.
        #expect(shell.backButton.frame.minX >= shell.collapsedTrigger.frame.maxX)
        #expect(shell.forwardButton.frame.minX >= shell.backButton.frame.maxX)
        // The breadcrumb starts after forward, on the same centre line inset.
        let lead = try? #require(shell.tabStrip.leadStart)
        #expect((lead ?? 0) + shell.tabStrip.frame.minX > shell.forwardButton.frame.maxX)
        if inset { #expect(shell.tabStrip.leadMidY.map { $0 + shell.tabStrip.frame.minY } == SidebarMetrics.topbarHeight / 2) }

        // Open again: the buttons move over the sidebar's right end, still on one row, and the strip leads as before.
        shell.setOpen(true, slides: false)
        shell.layoutSubtreeIfNeeded()
        #expect(shell.backButton.frame.midY == SidebarMetrics.topbarHeight / 2)
        #expect(shell.forwardButton.frame.maxX <= shell.effectiveWidth)
        #expect(shell.tabStrip.leadStart == nil)
    }
}
