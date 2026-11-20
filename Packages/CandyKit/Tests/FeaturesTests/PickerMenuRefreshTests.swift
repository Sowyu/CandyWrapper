import AppKit
import Testing
@testable import Features

/// A menu that stays open after a pick rebuilds its entries; the highlight from the old list must not outlive it.
@MainActor @Suite struct PickerMenuRefreshTests {
    final class Count { var value = 4 }

    @Test func refreshThatShrinksDropsTheHighlight() {
        let count = Count()
        func entries() -> [PickerMenuEntry] {
            (0..<count.value).map { i in
                var e = PickerMenuEntry.option("Item \(i)", checked: false) { count.value = 2 }
                e.keepsOpen = true
                return e
            }
        }
        let menu = PickerMenuView(entries: entries(), style: .menu, minimumWidth: 160)
        menu.refreshEntries = { entries() }
        menu.highlightedIndex = 3
        _ = menu.handleKey(.enter)
        #expect(menu.entries.count == 2)
        #expect(menu.highlightedIndex == nil)
        // Return again, and a stale pick from anywhere, do nothing instead of trapping.
        _ = menu.handleKey(.enter)
        menu.pick(3)
        _ = menu.handleKey(.down)
        #expect(menu.highlightedIndex == 0)
    }
}
