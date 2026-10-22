import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign floats everything T3 docks on the composer as separate pills; other themes keep T3's attached dock.
@MainActor
struct ComposerDitherPillsTests {
    private func panel(dither: Bool) throws -> (ThreadPanelView, NSWindow) {
        var input = ThemeRuntime.input
        input.ditherLight = dither; input.ditherDark = dither
        ThemeRuntime.apply(input)
        let panel = ThreadPanelView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":{"id":"t"},"runs":[],"updatedAt":"2026-10-22T00:00:00Z"}"#.utf8))
        panel.setProjection(projection, projectTitle: "Sandbox", workspaceRoot: nil)
        panel.stashBadge.count = 1
        panel.showsStashBadge = true
        panel.backgroundWorkBanner.apply(.init(variant: .neutral, icon: .info, title: "Running: Publish", actions: ["Stop"], priority: .activity))
        panel.showsBackgroundWork = true
        panel.layoutSubtreeIfNeeded()
        return (panel, window)
    }

    @Test func statusPillsFloatInARowAboveTheComposer() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(dither: true)
        defer { window.contentView = nil }
        let composer = panel.composer.frame, stash = panel.stashBadge.frame, work = panel.backgroundWorkBanner.frame
        #expect(!panel.stashBadge.isHidden && !panel.backgroundWorkBanner.isHidden)
        #expect(panel.stashBadge.placement == .floating && panel.backgroundWorkBanner.placement == .floating)
        // One 28pt row, 8 above the composer: the work pill from the left, Stash at the right, apart.
        for pill in [stash, work] {
            #expect(pill.height == DitherPill.height)
            #expect(pill.maxY == composer.minY - DitherPill.gap)
        }
        #expect(work.minX == composer.minX && stash.maxX == composer.maxX)
        #expect(work.maxX < stash.minX)
    }

    @Test func otherThemesKeepTheAttachedDock() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (panel, window) = try panel(dither: false)
        defer { window.contentView = nil }
        #expect(panel.stashBadge.placement == .attached && panel.backgroundWorkBanner.placement == .attached)
        // T3's tab and banner slide 17pt under the composer's top edge.
        #expect(panel.stashBadge.frame.maxY == panel.composer.frame.minY + ComposerBannerView.overlap)
    }
}
