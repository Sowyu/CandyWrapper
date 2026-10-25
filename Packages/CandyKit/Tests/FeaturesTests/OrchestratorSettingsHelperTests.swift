import AppKit
import DesignSystem
import Testing
@testable import Features
@testable import T3Store

/// While the CandyWrapper Helper is connected, the settings it replaces rest: "While closed" greys out with one line
/// and keeps its value, and comes back on its own when the helper stops.
@MainActor @Suite(.serialized) struct OrchestratorSettingsHelperTests {
    func rows(_ view: NSView) -> [SettingsRowView] {
        view.subviews.flatMap { v -> [SettingsRowView] in ((v as? SettingsRowView).map { [$0] } ?? []) + rows(v) }
    }

    @Test func whileClosedRestsWhileTheHelperRuns() throws {
        let store = OrchestratorStore.shared
        let saved = store.actions.helper
        defer { store.actions.helper = saved; store.actionsChanged() }
        var connected = true
        store.actions.helper = { .init(status: "Running on miniko.", primary: "Reinstall", canRun: true, installed: true, connected: connected) }
        let page = OrchestratorSettingsView(context: SettingsPageContext())
        page.frame = NSRect(x: 0, y: 0, width: 800, height: 2000)
        page.layoutSubtreeIfNeeded()
        let closed = try #require(rows(page).first { $0.title == "While closed" })
        #expect(closed.inertReason == "Handled by the Helper while it's running.")
        #expect(closed.status == "Handled by the Helper while it's running.")
        // Its value stays: the select still shows the setting.
        let select = try #require(closed.control as? SelectView)
        let shown = select.selectedIndex
        #expect(shown != nil)
        // The rest of the page stays live.
        #expect(rows(page).first { $0.title == "Worker limit" }?.inertReason == nil)
        // The helper stops: the row comes back by itself.
        connected = false
        store.actionsChanged()
        #expect(closed.inertReason == nil)
        #expect(closed.status == nil)
        #expect(select.selectedIndex == shown)
    }
}
