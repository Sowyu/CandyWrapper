import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// The Experimental Tabs switch: off by default, and off hides the tabs without dropping them.
@MainActor
struct ThreadTabsSettingTests {
    @Test func offByDefaultAndHidesTabsWithoutDroppingThem() throws {
        let saved = ThreadTabsSetting.defaults
        let suite = "ThreadTabsSettingTests-\(getpid())"
        ThreadTabsSetting.defaults = try #require(UserDefaults(suiteName: suite))
        defer { ThreadTabsSetting.defaults.removePersistentDomain(forName: suite); ThreadTabsSetting.defaults = saved }
        #expect(!ThreadTabsSetting.isOn)
        #expect(ExperimentalSettingsView.toggles.contains { $0.title == "Tabs" && $0.needsRedesign })
        var changes = 0
        let stop = ThreadTabsSetting.observe { changes += 1 }
        defer { stop() }
        ThreadTabsSetting.set(true)
        #expect(ThreadTabsSetting.isOn && changes == 1)

        let strip = DitherTabStripView(frame: NSRect(x: 0, y: 0, width: 900, height: 52))
        strip.tabs = [.init(id: "a", title: "One", icon: .messageSquare), .init(id: "b", title: "Two", icon: .messageSquare)]
        strip.layoutSubtreeIfNeeded()
        #expect(strip.accessibilityChildren()?.count == 3)
        strip.showsTabs = false
        strip.layoutSubtreeIfNeeded()
        #expect(strip.accessibilityChildren()?.isEmpty == true)
        strip.showsTabs = true
        strip.layoutSubtreeIfNeeded()
        #expect(strip.accessibilityChildren()?.count == 3)
    }
}
