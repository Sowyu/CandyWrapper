import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign's route modal: one 8pt radius (the user: "corner radius not consistent"), and Settings' page as one
/// inset card on the chrome with the close and Restore buttons inside it (settings-panes-mock.html, option B).
/// The default themes keep T3's 16pt card, divider and header bar.
@MainActor
struct RouteModalCardTests {
    static func modal(dither: Bool, width: CGFloat, title: String = "General") -> (AppRouteModalView, SettingsPageView) {
        var input = ThemeRuntime.input
        input.ditherLight = dither; input.ditherDark = dither
        ThemeRuntime.apply(input)
        let page = SettingsPageView()
        page.header.isRouteModal = true
        page.header.section = .general
        page.header.restore.isHidden = false
        page.page = SettingsStackView()
        page.ditherHeading = (title, "")
        let nav = DSView()
        let modal = AppRouteModalView(label: "Settings", content: page, navigation: nav)
        modal.frame = NSRect(x: 0, y: 0, width: width, height: 780)
        modal.layoutSubtreeIfNeeded()
        page.layoutSubtreeIfNeeded()
        return (modal, page)
    }

    @Test func radiusIsRedesignsPanelOrT3s16() {
        #expect(AppRouteModalView.radius(width: 1100, dither: true) == RedesignTokens.Radius.panel)
        #expect(AppRouteModalView.radius(width: 1100, dither: false) == 16)
        #expect(AppRouteModalView.radius(width: 600, dither: true) == 0)
    }

    @Test(arguments: [1100, 840] as [CGFloat]) func pageCardSitsEightFromEveryEdge(width: CGFloat) {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (modal, page) = Self.modal(dither: true, width: width)
        let surface = modal.surface.bounds, card = modal.pageCard.frame
        #expect(!modal.pageCard.isHidden && page.superview === modal.pageCard && page.inCard)
        #expect(modal.surface.layer?.cornerRadius == 8 && modal.pageCard.layer?.cornerRadius == 8)
        #expect(card.minY == 1 + 8 && surface.maxX - card.maxX == 1 + 8 && surface.maxY - card.maxY == 1 + 8)
        let navWidth: CGFloat = width >= 768 ? 240 : 56
        #expect(card.minX == 1 + navWidth + 8)
        // Close and Restore float inside the card's top right, clear of the title.
        let close = page.header.close.frame, restore = page.header.restore.frame
        #expect(close.maxX == page.bounds.width - 8 && close.minY == 8 && close.width == 24)
        #expect(restore.maxX <= close.minX && restore.midY == close.midY && restore.minX > 0)
        let title = page.ditherTitle.convert(page.ditherTitle.bounds, to: page)
        #expect(title.maxX <= restore.minX || title.minY >= close.maxY)
    }

    @Test func aLongTitleTakesTheRowUnderTheButtons() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (_, page) = Self.modal(dither: true, width: 840, title: "A very long settings page title that runs into the buttons")
        let title = page.ditherTitle.convert(page.ditherTitle.bounds, to: page)
        #expect(title.minY >= page.header.close.frame.maxY)
    }

    @Test func defaultThemesKeepT3sFrame() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (modal, page) = Self.modal(dither: false, width: 1100)
        #expect(modal.pageCard.isHidden && page.superview === modal.surface && !page.inCard)
        #expect(modal.surface.layer?.cornerRadius == 16)
        #expect(page.header.frame.height == page.header.barHeight)
    }
}
