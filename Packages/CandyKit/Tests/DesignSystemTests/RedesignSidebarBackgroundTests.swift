import AppKit
import Testing
@testable import DesignSystem

/// Redesign's background stays in the content panel: the sidebar keeps its opaque fill and never holds the art.
@MainActor
struct RedesignSidebarBackgroundTests {
    @Test func theArtStaysInTheContentPanel() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let shell = SidebarLayoutView(defaults: UserDefaults(suiteName: "RedesignSidebarBackgroundTests")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        window.contentView = shell
        shell.viewDidChangeEffectiveAppearance()
        shell.layoutSubtreeIfNeeded()
        #expect(!shell.sidebar.surface.clearsFill)
        #expect(shell.main.subviews.contains { $0 is DitherArtView })
        #expect(!shell.subviews.contains { $0 is DitherArtView })
        #expect(!shell.sidebar.subviews.contains { $0 is DitherArtView })
    }
}
