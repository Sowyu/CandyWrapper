import AppKit
import Testing

@testable import DesignSystem

/// How a menu row marks the current choice: T3's resting fill in the default themes (menu.tsx:239
/// `data-checked:bg-foreground/[0.08]`), a trailing check and no resting fill under Redesign.
@MainActor
struct MenuViewTests {
    private func withTheme(dither: Bool, _ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = dither; input.ditherDark = dither
        ThemeRuntime.apply(input)
        try body()
    }

    private func row(checked: Bool, style: MenuPopupView.Style = .menu) -> MenuRowView {
        let row = MenuRowView(item: .radio("Light", checked: checked), style: style)
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func fill(_ row: MenuRowView) -> NSColor? {
        row.layer?.sublayers?.lazy.compactMap { $0 as? BoxDecorationLayer }.first?.boxStyle.fill
    }

    private func checkMark(_ row: MenuRowView) -> IconView? {
        row.subviews.lazy.compactMap { $0 as? IconView }.first { !$0.isHidden && $0.name == .check }
    }

    @Test func redesignMarksTheChoiceWithACheckAndNoRestingFill() {
        withTheme(dither: true) {
            for style in [MenuPopupView.Style.menu, .select, .combobox, .autocomplete] {
                let chosen = row(checked: true, style: style)
                #expect(fill(chosen) == nil)
                let mark = checkMark(chosen)
                #expect(mark != nil)
                // At the trailing edge, where a submenu chevron sits.
                #expect(mark?.frame == NSRect(x: 200 - 8 + 2 - 16, y: 6, width: 16, height: 16))
                #expect(checkMark(row(checked: false, style: style)) == nil)
            }
        }
    }

    /// A select list opened by the pointer (Settings > General > Message rail ticks) shows its choice with the check
    /// alone under Redesign; the first arrow key then lands on the choice. The default themes and a keyboard open
    /// highlight the choice at once, as base-ui does.
    @Test func aSelectOpenedByThePointerHasNoRestingHighlight() {
        let items = ["Off", "Light", "Standard"].enumerated().map { MenuItem($1, kind: .radio($0 == 1)) }
        withTheme(dither: true) {
            let list = MenuPopupView(items: items, style: .select)
            list.highlightOnOpen(1, byKeyboard: false)
            #expect(list.highlightedIndex == nil)
            #expect(list.popupHandleKey(.down))
            #expect(list.highlightedIndex == 1)
            let keyed = MenuPopupView(items: items, style: .select)
            keyed.highlightOnOpen(1, byKeyboard: true)
            #expect(keyed.highlightedIndex == 1)
        }
        withTheme(dither: false) {
            let list = MenuPopupView(items: items, style: .select)
            list.highlightOnOpen(1, byKeyboard: false)
            #expect(list.highlightedIndex == 1)
        }
    }

    @Test func redesignHoveredChoiceShowsFillAndCheck() {
        withTheme(dither: true) {
            let chosen = row(checked: true)
            chosen.highlighted = true
            #expect(fill(chosen) != nil)
            #expect(checkMark(chosen) != nil)
        }
    }

    @Test func defaultThemesKeepT3sCheckedFill() {
        withTheme(dither: false) {
            let chosen = row(checked: true)
            #expect(fill(chosen) != nil)
            #expect(checkMark(chosen) == nil)
            #expect(fill(row(checked: false)) == nil)
        }
    }
}
