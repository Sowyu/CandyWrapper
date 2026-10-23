import AppKit
import Testing
@testable import DesignSystem

/// Redesign's header controls sit at the right of the tab band: the tabs shrink, then scroll to the selected one, and
/// never run under them.
@MainActor
struct DitherTabStripAccessoryTests {
    final class Fixed: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 260, height: DitherTabStripView.tabHeight) }
    }

    @Test func tabsNeverRunUnderTheAccessory() throws {
        let strip = DitherTabStripView(frame: NSRect(x: 0, y: 0, width: 700, height: 52))
        let pill = Fixed()
        strip.trailingAccessory = pill
        strip.tabs = (0..<12).map { .init(id: "\($0)", title: "Thread \($0)", icon: .messageSquare) }
        strip.selected = "11"
        strip.layoutSubtreeIfNeeded()
        #expect(pill.frame.maxX == 690)
        #expect(pill.frame.midY == 26)
        let tabs = try #require(strip.accessibilityTabs() as? [NSView])
        let shown = tabs.filter { !$0.isHidden }
        #expect(shown.count < tabs.count)
        #expect(tabs.last.map { !$0.isHidden } == true)
        #expect(shown.allSatisfy { $0.frame.maxX < pill.frame.minX })
        let sameLine = shown.allSatisfy { $0.frame.midY == pill.frame.midY && $0.frame.height == pill.frame.height }
        #expect(sameLine)
    }

    @Test func windowKeepsTheSelectedTab() {
        #expect(DitherTabStripView.window(count: 3, selected: 2, room: 1000) == 0..<3)
        let fits = Int((300 + DitherTabStripView.gap) / (DitherTabStripView.minTabWidth + DitherTabStripView.gap))
        #expect(DitherTabStripView.window(count: 10, selected: 0, room: 300) == 0..<fits)
        #expect(DitherTabStripView.window(count: 10, selected: 9, room: 300) == (10 - fits)..<10)
    }
}
