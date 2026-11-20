import AppKit
import DesignSystem
import Testing
@testable import Features

/// Settings > Appearance rebuilds its theme cards when what they show changes. A refresh that changes nothing
/// must keep every swatch: no new render and the same picture, or the circles flash empty while a render runs.
@MainActor
struct ThemeSwatchTests {
    private func cards() -> [ThemeLibraryCardView] {
        let none = ThemeLibraryCardView.Actions(use: {}, useMode: { _ in }, duplicate: {})
        return [ThemeLibraryCardView(card: .standard, picked: [.dark], actions: none)]
            + ThemeDefinition.builtIns.map { ThemeLibraryCardView(card: ThemeCardDefinition($0), picked: [], actions: none) }
    }

    private func draw(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    private func pictures(_ grid: ThemeCardGridView) -> [CGImage?] { grid.cards.flatMap { $0.circles.map(\.ball.image) } }

    @Test func rebuiltCardsWithUnchangedThemesReuseTheirSwatches() throws {
        let grid = ThemeCardGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        grid.cards = cards()
        draw(grid)
        let first = pictures(grid)
        #expect(first.allSatisfy { $0 != nil })
        let renders = ThemePreviewCircleView.renderCount
        grid.cards = cards()
        // Before the new cards draw, they already show the old pictures.
        #expect(zip(first, pictures(grid)).allSatisfy { $0 === $1 })
        draw(grid)
        #expect(ThemePreviewCircleView.renderCount == renders)
        #expect(zip(first, pictures(grid)).allSatisfy { $0 === $1 })
    }

    @Test func reopenedSettingsDrawsSwatchesFromTheCache() {
        // Closing Settings drops its pages, so the next open builds new cards with no picture to hand over.
        let first = ThemeCardGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        first.cards = cards()
        draw(first)
        let renders = ThemePreviewCircleView.renderCount
        let reopened = ThemeCardGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        reopened.cards = cards()
        draw(reopened)
        #expect(ThemePreviewCircleView.renderCount == renders)
        #expect(zip(pictures(first), pictures(reopened)).allSatisfy { $0 === $1 })
    }

    @Test func equalThemesMakeEqualGridContent() {
        // The grid used a string key built from dictionary descriptions, whose order differs between equal
        // dictionaries, so it rebuilt on every refresh.
        let themes = ThemeDefinition.builtIns
        let a = AppearanceSettingsView.ThemeGridContent(picked: [[.dark]], custom: themes.map(ThemeCardDefinition.init))
        for _ in 0..<20 {
            #expect(AppearanceSettingsView.ThemeGridContent(picked: [[.dark]], custom: themes.map(ThemeCardDefinition.init)) == a)
        }
    }
}
