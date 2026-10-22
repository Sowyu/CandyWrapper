import AppKit
import Testing
@testable import DesignSystem

/// A Dither tab whose thread works shows the dot grid in the close button's slot, and drops it when the run ends.
@MainActor
struct DitherTabActivityTests {
    func grid(_ tab: NSView) -> DotGridSpinnerView? { tab.subviews.compactMap { $0 as? DotGridSpinnerView }.first }

    @Test func workingTabShowsTheGridInTheCloseSlot() throws {
        let strip = DitherTabStripView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        strip.tabs = [.init(id: "a", title: "Moon", icon: .messageSquare, activity: .working),
                      .init(id: "b", title: "Sun", icon: .messageSquare)]
        strip.selected = "a"
        strip.layoutSubtreeIfNeeded()
        let tabs = try #require(strip.accessibilityTabs() as? [NSView])
        tabs.forEach { $0.layoutSubtreeIfNeeded() }
        let working = try #require(grid(tabs[0]))
        #expect(!working.isHidden)
        let close = try #require(tabs[0].subviews.first { $0.accessibilityLabel() == "Close tab" })
        // Selected but not hovered: the grid holds the slot and the close button waits for the pointer.
        #expect(close.alphaValue == 0)
        #expect(working.frame == close.frame)
        #expect(grid(tabs[1]) == nil)

        strip.tabs = [.init(id: "a", title: "Moon", icon: .messageSquare), .init(id: "b", title: "Sun", icon: .messageSquare)]
        #expect(working.isHidden)
        #expect(close.alphaValue == 1)
    }
}
