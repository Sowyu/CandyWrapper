import AppKit
import Testing
@testable import DesignSystem

/// Redesign's Picture background stays in the content panel: the sidebar keeps its opaque fill over it, and only Blur
/// clears the sidebar and puts the art behind the whole window. Diagonal stripes in an offscreen render of the bare
/// sidebar content (sprite-avatars-2026-11-21/sidebar.png) are the test picture behind a view drawn without its shell.
@MainActor
struct RedesignSidebarBackgroundTests {
    @Test(arguments: [false, true]) func onlyBlurPutsThePictureUnderTheSidebar(blur: Bool) {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = true; input.ditherDark = true
        input.ditherBlur = blur
        ThemeRuntime.apply(input)
        let shell = SidebarLayoutView(defaults: UserDefaults(suiteName: "RedesignSidebarBackgroundTests")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        window.contentView = shell
        shell.viewDidChangeEffectiveAppearance()
        shell.layoutSubtreeIfNeeded()
        #expect(shell.sidebar.surface.clearsFill == blur)
        let art = shell.subviews.contains { $0 is DitherArtView }
        #expect(art == blur)
        #expect(!shell.sidebar.subviews.contains { $0 is DitherArtView })
    }
}
