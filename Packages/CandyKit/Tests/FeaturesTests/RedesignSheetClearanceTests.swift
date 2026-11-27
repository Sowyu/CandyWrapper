import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign's right panel sheet covers the thread's text but never cuts a control: the composer and the pills and
/// cards around it sit wholly left of the sheet's edge, at the widths where the panel opens as a sheet.
@MainActor
struct RedesignSheetClearanceTests {
    @Test func columnStaysClearOfTheSheet() {
        let pad = RedesignTokens.Space.s
        for clear in [120, 269, 364, 533, 900] as [CGFloat] {
            let lane = ThreadPanelView.sheetColumn(clear: clear, maximum: 720)
            #expect(lane.x >= pad && lane.x + lane.width <= clear - pad, "\(clear): \(lane)")
        }
        let narrow = ThreadPanelView.sheetColumn(clear: 364, maximum: 720)
        #expect(narrow.x == pad && narrow.width == 364 - 2 * pad)
        // Never wider than the thread's own lane.
        #expect(ThreadPanelView.sheetColumn(clear: 900, maximum: 720).width == 720)
    }

    /// Window widths with the sidebar open (a 280pt sidebar) and hidden (the inset card's margins).
    @Test(arguments: [960, 1100, 1250] as [CGFloat], [280, 16] as [CGFloat])
    func noControlCrossesTheSheetEdge(viewport: CGFloat, chrome: CGFloat) throws {
        let previous = ThemeRuntime.input
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        Motion.reducedOverride = true
        let width = viewport - chrome
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: width, height: 780))
        panel.referenceViewportWidth = viewport
        window.contentView = panel
        defer { window.contentView = nil; window.close(); ThemeRuntime.apply(previous); Motion.reducedOverride = nil }
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        panel.mutatePanel { $0.open(.diff); return [] }
        for _ in 0..<2 { panel.layoutSubtreeIfNeeded() }
        guard panel.rightPanel.isSheet else { return }
        let edge = panel.rightPanel.frame.minX
        var controls: [NSView] = [panel.composer, panel.deviceRow, panel.composer.contextWindowMeter]
        controls += panel.subviews.filter { $0 is ComposerBannerView }
        for view in controls where !view.isHidden && view.superview === panel && view.frame.width > 0 {
            let f = view.frame
            #expect(f.maxX <= edge - RedesignTokens.Space.s || f.minX >= edge, "\(type(of: view)) \(f) cut by the sheet at \(edge)")
        }
        #expect(!panel.composer.isHidden && panel.composer.frame.width > 0)
    }
}
