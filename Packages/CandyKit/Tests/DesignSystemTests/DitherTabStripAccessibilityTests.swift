import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct DitherTabStripAccessibilityTests {
    @Test func tabsAreATabGroupWithACloseAction() throws {
        let strip = DitherTabStripView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        var closed: [String] = []
        strip.onClose = { closed.append($0) }
        strip.tabs = [.init(id: "a", title: "First", icon: .messageSquare), .init(id: "b", title: "Second", icon: .messageSquare)]
        strip.selected = "a"
        #expect(strip.accessibilityRole() == .tabGroup)
        let tabs = try #require(strip.accessibilityTabs() as? [NSView])
        #expect(tabs.map { $0.accessibilityLabel() } == ["First", "Second"])
        #expect(tabs.map { $0.accessibilityRole() } == [.radioButton, .radioButton])
        let close = try #require(tabs[1].accessibilityCustomActions()?.first)
        #expect(close.name == "Close tab")
        #expect(close.handler?() == true)
        #expect(closed == ["b"])
    }

    @Test func restingTabsStayReadable() {
        let normal = DitherTabStripView.TabView.restingAlpha(increaseContrast: false)
        let high = DitherTabStripView.TabView.restingAlpha(increaseContrast: true)
        #expect(normal.label >= 0.7)
        #expect(high.label > normal.label && high.icon > normal.icon)
    }
}
