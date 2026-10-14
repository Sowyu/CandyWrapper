import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// The thread panel's header and the draft hero across column widths.
@MainActor
struct ThreadPanelChromeTests {
    /// The header keeps its panel toggles hidden while no thread shows, through layouts, so they and the details
    /// shortcut stay off before a thread loads.
    @Test func classicHeaderTogglesStayHiddenWithoutAThread() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
        window.contentView = panel
        panel.header.setThreadVisible(false)
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.header.toggles.allSatisfy { $0.isHidden })
        panel.setFrameSize(NSSize(width: 1200, height: 800))
        panel.layoutSubtreeIfNeeded()
        #expect(panel.header.toggles.allSatisfy { $0.isHidden })
        window.contentView = nil
    }

    /// The draft headline wraps at spaces in a narrow column, as T3's `h1` does, keeps the project picker whole,
    /// and stays one line where it fits.
    @Test func draftHeadlineWrapsInANarrowColumn() {
        let hero = DraftHeroView(frame: .zero)
        hero.projectTitle = "demo-repo"
        #expect(hero.headlineLines(width: 900).count == 1)
        #expect(hero.height(forWidth: 900) == DraftHeroView.height)
        let lines = hero.headlineLines(width: 380)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.line.width <= 380 })
        let project = ("What should we build in " as NSString).length
        #expect(lines.contains { $0.start <= project && project + 9 <= $0.start + $0.length })
        #expect(hero.height(forWidth: 380) == DraftHeroView.height + 36)
    }
}
