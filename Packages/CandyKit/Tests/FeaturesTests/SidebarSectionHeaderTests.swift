import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import Features

/// The sidebar's Working, Snoozed and Settled headers: Redesign's colors and strip, the default themes' rule.
@MainActor @Suite(.serialized)
struct SidebarSectionHeaderTests {
    static func header(_ shelf: SidebarShelf, dark: Bool, drag: CollapsibleSectionHeaderView.Tone? = nil) -> SidebarShelfRowView {
        let row = SidebarShelfRowView(frame: NSRect(x: 0, y: 0, width: 264, height: 32))
        row.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        row.item = .shelfHeader(shelf, label: "\(shelf.rawValue.capitalized) (2)", expanded: false, count: 2)
        row.dragTone = drag
        row.refresh()
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test(arguments: [false, true]) func redesignTakesTheAccentForSnoozedAndTheDimColorElsewhere(dark: Bool) {
        RedesignStatesTests.withRedesign(true) {
            #expect(Self.header(.snoozed, dark: dark).header.tone == .accent)
            #expect(Self.header(.settled, dark: dark).header.tone == .muted)
            #expect(Self.header(.working, dark: dark).header.tone == .muted)
            // A drag still lights Settled up as T3 does.
            #expect(Self.header(.settled, dark: dark, drag: .accent).header.tone == .accent)
            #expect(Self.header(.settled, dark: dark).header.dithersRule)
        }
    }

    @Test func defaultThemesKeepTheInfoBlue() {
        RedesignStatesTests.withRedesign(false) {
            #expect(Self.header(.snoozed, dark: true).header.tone == .info)
            #expect(Self.header(.settled, dark: true).header.tone == .muted)
        }
    }

    /// The strip shows only under Redesign, and only on the sidebar's headers.
    @Test func stripOnlyUnderRedesign() {
        func strip(_ h: CollapsibleSectionHeaderView) -> (rule: Bool, strip: Bool) {
            let layers = h.layer?.sublayers ?? []
            let rule = layers.first { $0.mask == nil && $0.frame.height == 1 }
            let strip = layers.first { $0.mask != nil }
            return (rule.map { !$0.isHidden } ?? false, strip.map { !$0.isHidden && $0.frame.width > 0 } ?? false)
        }
        RedesignStatesTests.withRedesign(true) {
            let h = Self.header(.snoozed, dark: true).header
            #expect(strip(h) == (false, true))
            let plain = CollapsibleSectionHeaderView("Previous agents")
            plain.appearance = NSAppearance(named: .darkAqua)
            plain.frame = NSRect(x: 0, y: 0, width: 264, height: 32); plain.layoutSubtreeIfNeeded()
            #expect(strip(plain).strip == false)
        }
        RedesignStatesTests.withRedesign(false) {
            // T3's shelf header shows the count as an accessory and no rule there; the strip stays out too.
            #expect(strip(Self.header(.snoozed, dark: true).header).strip == false)
        }
    }
}
