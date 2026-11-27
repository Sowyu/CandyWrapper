import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign's inset panel: the thread card, the right panel card and the terminal drawer card each keep `Space.s` to the
/// window's edges, the sidebar and each other.
@MainActor @Suite(.serialized) struct InsetPanelLayoutTests {
    @Test func cardsKeepTheirGaps() throws {
        let previous = ThemeRuntime.input, duration = SettingsPanelMotion.durationMs, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); SettingsPanelMotion.durationMs = duration; Motion.reducedOverride = motion }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true; input.insetPanel = true
        ThemeRuntime.apply(input)
        SettingsPanelMotion.durationMs = 0; Motion.reducedOverride = true

        let defaults = try #require(UserDefaults(suiteName: "inset-panel-layout-tests"))
        defaults.removePersistentDomain(forName: "inset-panel-layout-tests")
        let panel = ComposerFidelityTests.panel(width: 1200, dark: true)
        panel.referenceViewportWidth = 1440
        let layout = SidebarLayoutView(sidebarContent: DSView(), mainContent: panel, defaults: defaults, viewport: 1440)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = layout
        defer { window.contentView = nil }
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        layout.layoutSubtreeIfNeeded()

        let s = RedesignTokens.Space.s, w = layout.bounds.width, h = layout.bounds.height
        func card() -> NSRect { layout.convert(layout.insetCardFrame, from: layout.main) }
        #expect(card() == NSRect(x: layout.main.frame.minX + s, y: s, width: w - layout.main.frame.minX - 2 * s, height: h - 2 * s))
        #expect(layout.tabStrip.frame.minY == s && layout.tabStrip.frame.height == CardTopRow.floatHeight)
        #expect(layout.convert(panel.bounds, from: panel).minY == s + CardTopRow.rowHeight)
        // No band: the rows run to the card's top behind the floating pills, and start below them at rest.
        #expect(layout.convert(panel.timeline.frame, from: panel).minY == s)
        #expect(panel.timeline.topClearance >= CardTopRow.floatHeight)

        panel.mutatePanel { $0.open(.diff); $0.isOpen = true; return [] }
        layout.layoutSubtreeIfNeeded()
        let right = layout.convert(panel.rightPanel.frame, from: panel)
        #expect(right.minX - card().maxX == s)
        #expect(right.maxX == w - s && right.minY == s && right.maxY == h - s)
        #expect(card().minY == s && card().maxY == h - s)

        panel.setTerminal(open: true, height: 200)
        layout.layoutSubtreeIfNeeded()
        let drawer = layout.convert(panel.terminalDrawer.frame, from: panel)
        // The drawer floats inside the full-height thread card, over its art, `Space.s` from its sides and bottom.
        #expect(card().minY == s && card().maxY == h - s)
        #expect(drawer.maxY == card().maxY - s && drawer.minX == card().minX + s && drawer.maxX == card().maxX - s)
        #expect(right.minX - card().maxX == s)
    }

    /// The art's ground runs behind the floating drawer, and with the inset panel off behind the right panel too (the
    /// user, 2026-11-26: "the background isnt showing underneath"). A thread shows no cells: plain ground.
    @Test(arguments: [false, true])
    func groundRunsBehindTheFloatingCards(inset: Bool) throws {
        let previous = ThemeRuntime.input, duration = SettingsPanelMotion.durationMs, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); SettingsPanelMotion.durationMs = duration; Motion.reducedOverride = motion }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true; input.insetPanel = inset
        ThemeRuntime.apply(input)
        SettingsPanelMotion.durationMs = 0; Motion.reducedOverride = true

        let suite = "art-behind-cards-tests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let panel = ComposerFidelityTests.panel(width: 1200, dark: true)
        panel.referenceViewportWidth = 1440
        let layout = SidebarLayoutView(sidebarContent: DSView(), mainContent: panel, defaults: defaults, viewport: 1440)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = layout
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: panel) }
        func arts(_ v: NSView) -> [DitherArtView] { (v as? DitherArtView).map { [$0] } ?? v.subviews.flatMap(arts) }
        let art = try #require(arts(layout).first)
        art.rendersInlineForTesting = true
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        DitherArtView.setEmphasis(.thread, from: panel)
        panel.mutatePanel { $0.open(.diff); $0.isOpen = true; return [] }
        panel.setTerminal(open: true, height: 200)
        for _ in 0..<2 { layout.layoutSubtreeIfNeeded() }
        art.refresh()

        let drawer = art.convert(panel.terminalDrawer.frame, from: panel)
        let right = art.convert(panel.rightPanel.frame, from: panel)
        #expect(!panel.terminalDrawer.isHidden && !panel.rightPanel.isHidden)
        // The cards the art runs behind: the drawer always; the right panel only off the inset, where it sits over the
        // art rather than beside the thread's card.
        let behind = inset ? [drawer] : [drawer, right]
        for card in behind { #expect(art.bounds.contains(card), "art \(art.bounds) card \(card)") }
        #expect(art.requestForTesting == nil && !art.showsCellsForTesting)
    }
}
