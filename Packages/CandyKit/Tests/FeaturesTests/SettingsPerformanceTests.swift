import AppKit
import DesignSystem
import Testing
import T3Protocol
@testable import Features

@MainActor
struct SettingsPerformanceTests {
    @Test func keybindingSearchBuildsCatalogOnce() {
        var builds = 0
        let catalog = KeybindingsCatalog { rules in
            builds += 1
            return KeybindingsLogic.rows(rules)
        }
        for query in ["", "composer", "composer.", "composer.send", ""] {
            catalog.update([])
            let filtered = KeybindingsLogic.filter(catalog.rows, query: query)
            #expect(filtered == KeybindingsLogic.rows(Keymap.merged(withServer: []).rules, query: query))
        }
        #expect(builds == 1)
        catalog.update(Array(Keymap.default.rules.prefix(1)))
        #expect(builds == 2)
    }

    @Test func keybindingSearchRetainsUnchangedSectionsAndRows() {
        let page = KeybindingsSettingsView(context: SettingsPageContext())
        page.query = "composer."
        let sections = page.items.compactMap { $0 as? SettingsSectionView }
        let rows = page.rows.compactMap { page.anchors[KeybindingsLogic.anchorId($0.command)] }
        page.query = "COMPOSER."
        let nextSections = page.items.compactMap { $0 as? SettingsSectionView }
        let nextRows = page.rows.compactMap { page.anchors[KeybindingsLogic.anchorId($0.command)] }
        #expect(!rows.isEmpty)
        #expect(zip(sections, nextSections).filter { $0 !== $1 }.count == 0)
        #expect(zip(rows, nextRows).filter { $0 !== $1 }.count == 0)
        page.query = "composer.send"
        let remaining = page.rows.compactMap { page.anchors[KeybindingsLogic.anchorId($0.command)] }
        #expect(!remaining.isEmpty)
        #expect(remaining.allSatisfy { row in rows.contains { $0 === row } })
    }
}
