import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign's route modal: one 8pt radius (the user: "corner radius not consistent"), and Settings' page as one
/// inset card on the chrome with the close and Restore buttons inside it (settings-panes-mock.html, option B).
/// The default themes keep T3's 16pt card, divider and header bar.
@MainActor
struct RouteModalCardTests {
    static func modal(dither: Bool, width: CGFloat, title: String = "General",
                      content: (NSView & SettingsGroupRow)? = nil) -> (AppRouteModalView, SettingsPageView) {
        var input = ThemeRuntime.input
        input.ditherLight = dither; input.ditherDark = dither
        ThemeRuntime.apply(input)
        let page = SettingsPageView()
        page.header.isRouteModal = true
        page.header.section = .general
        page.header.restore.isHidden = false
        page.page = content ?? SettingsStackView()
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
        // Right under the 40pt row, at the scroll's top: where the dropped title sat before the row was fixed.
        #expect(title.minY == 40 && page.ditherTitle.superview !== page)
    }

    /// The page scrolls only below the card's fixed 40pt top row, so a scrolled row never runs under close or
    /// Restore (1.16.0: "Restore device defaults" drew over the Delete confirmation toggle).
    @Test(arguments: [1100, 840] as [CGFloat]) func scrolledRowsStayClearOfTheControls(width: CGFloat) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (_, page) = Self.modal(dither: true, width: width, content: GeneralSettingsView(context: SettingsPagesFidelityTests.context()))
        #expect(page.rowRule.isHidden)
        page.scroll.scroll(to: NSPoint(x: 0, y: 300))
        #expect(page.scroll.scrollView.contentView.bounds.minY == 300)
        #expect(!page.rowRule.isHidden && page.rowRule.frame.maxY == 40)
        let controls = [page.header.close.frame, page.header.restore.frame]
        #expect(page.scroll.frame.minY >= controls.map(\.maxY).max()!)
        let general = try #require(page.page)
        func rows(_ view: NSView) -> [NSView] { view.isHidden ? [] : [view] + view.subviews.flatMap(rows) }
        var checked = 0
        for row in rows(general) {
            // What the page draws of the row: its frame clipped to the scroll area.
            let drawn = row.convert(row.bounds, to: page).intersection(page.scroll.frame)
            guard !drawn.isEmpty else { continue }
            checked += 1
            for control in controls { #expect(!drawn.intersects(control), "\(type(of: row)) \(drawn) under \(control)") }
        }
        #expect(checked > 10)
    }

    /// At rest the title moves up 10pt from 16 into the row, centred on the buttons, and the page keeps its 28pt
    /// under it, so the first section moves up 10 too (72 to 62).
    @Test(arguments: [1100, 840] as [CGFloat]) func restingTitleSitsInTheTopRow(width: CGFloat) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let (_, page) = Self.modal(dither: true, width: width)
        // General as the app shows it: titled by its section, no subtitle line.
        page.ditherHeading = nil
        page.layoutSubtreeIfNeeded()
        let title = page.ditherTitle.convert(page.ditherTitle.bounds, to: page)
        #expect(title.minY == 6 && title.midY == page.header.close.frame.midY)
        let first = try #require(page.page)
        #expect(first.convert(first.bounds, to: page).minY == 62)
        #expect(page.scroll.frame.minY == 40 && page.header.frame.height == 40)
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
