import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Under Redesign no setting, search result or menu describes or controls something that isn't on screen.
@MainActor @Suite struct RedesignIntegrationTests {
    private let previous = ThemeRuntime.input

    private func withRedesign(_ on: Bool, _ body: () throws -> Void) rethrows {
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = on; input.ditherDark = on
        ThemeRuntime.apply(input)
        try body()
    }

    private func appearancePage() -> AppearanceSettingsView {
        let page = AppearanceSettingsView(context: SettingsPagesFidelityTests.context())
        page.frame = NSRect(x: 0, y: 0, width: 800, height: page.height(forWidth: 800))
        page.layoutSubtreeIfNeeded()
        return page
    }

    @Test func hiddenRowsLeaveThePageAndSearch() {
        #expect(!SettingsSearch.hiddenUnderRedesign.isEmpty)
        var redesign = SettingsSearchAvailability()
        redesign.redesign = true
        let ids = Set(SettingsSearch.available(redesign).map(\.id))
        let plainIds = Set(SettingsSearch.available(SettingsSearchAvailability()).map(\.id))
        for id in SettingsSearch.hiddenUnderRedesign {
            #expect(!ids.contains(id), "\(id) is a Redesign search result")
            #expect(plainIds.contains(id), "\(id) left the default themes' search")
        }
        withRedesign(true) {
            let page = appearancePage()
            for id in SettingsSearch.hiddenUnderRedesign { #expect(page.anchor(id) == nil, "\(id) shows under Redesign") }
            // Every Redesign result that lands on Appearance finds its row there.
            for item in SettingsSearch.available(redesign) where item.to == .appearance {
                #expect(page.anchor(item.anchor) != nil, "\(item.id) points at a row Redesign hides")
            }
        }
        withRedesign(false) {
            let page = appearancePage()
            for id in SettingsSearch.hiddenUnderRedesign { #expect(page.anchor(id) != nil, "\(id) left the default themes") }
        }
    }

    @Test func redesignSearchNamesNoRetiredSurface() {
        var redesign = SettingsSearchAvailability()
        redesign.redesign = true
        for item in SettingsSearch.available(redesign) {
            let terms = item.searchTerms.joined(separator: " ")
            #expect(!terms.contains("gradient"), "\(item.id)")
            if item.id == "thread-details-items" { #expect(!terms.contains("card") && !terms.contains("context window")) }
        }
        #expect(SettingsSearch.search("gradient", in: SettingsSearch.available(redesign)).isEmpty)
        #expect(SettingsSearch.search("glass", in: SettingsSearch.available(redesign)).isEmpty)
    }

    @Test func threadDetailsOffersOnlyWhatRedesignShows() {
        let redesign = ThreadDetailsItems.items(redesign: true).map(\.id)
        #expect(!redesign.contains("environment") && !redesign.contains("context"))
        #expect(redesign.count == ThreadDetailsItems.all.count - 2)
        let menu = ThreadDetailsItems.menuItems(redesign: true, settings: { .defaults }, write: { _ in }).map(\.title)
        #expect(!menu.contains("Environment and worktree") && !menu.contains("Context window"))
        // Reset under Redesign keeps the items it doesn't offer, so the other themes get them back.
        var settings = ClientSettings.defaults
        settings.apply(["threadDetailsItems": .object(["environment": .bool(false), "openIn": .bool(false), "context": .bool(true)])])
        let patch = ThreadDetailsItems.reset(settings, redesign: true)
        #expect(patch["threadDetailsItems"] == .object(["environment": .bool(false), "context": .bool(true)]))
        settings.apply(patch)
        #expect(ThreadDetailsItems.isDefault(ThreadDetailsItems.visibility(settings), redesign: true))
        #expect(!ThreadDetailsItems.isDefault(ThreadDetailsItems.visibility(settings)))
    }

    @Test func thePillsMenuFollowsThreadDetails() {
        let pill = DitherHeaderPillView()
        pill.menuSections[.editor] = { [MenuItem("Open in Zed")] }
        pill.menuSections[.scripts] = { [MenuItem("Run tests")] }
        pill.menuSections[.git] = { [MenuItem("Commit")] }
        #expect(pill.menuItems(shown: [:]).map(\.title) == ["Open in Zed", "", "Run tests", "", "Commit"])
        #expect(pill.menuItems(shown: ["openIn": false, "gitActions": false]).map(\.title) == ["Run tests"])
    }

    @Test func appearanceRowsDescribeRedesign() {
        withRedesign(true) {
            let page = appearancePage()
            let details = page.anchor("thread-details-items") as? SettingsRowView
            #expect(details?.detail == AppearanceSettingsView.redesignThreadDetailsDetail)
            #expect((page.anchor("panel-animations") as? SettingsRowView)?.detail == AppearanceSettingsView.redesignMotionDetail)
        }
        #expect(AppearanceSettingsView.redesignNotice([.light, .dark], under: "Ocean")
                == "Redesign is on. When you turn it off, you get Ocean. Pick a theme here to change that.")
        #expect(ThemeRuntime.appName(dark: true) == (ThemeRuntime.isDither(dark: true) ? "CandyWrapper" : "T3 Code"))
    }
}
