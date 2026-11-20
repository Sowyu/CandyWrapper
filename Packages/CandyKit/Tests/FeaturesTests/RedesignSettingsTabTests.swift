import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Redesign: the master switch is the theme picker's setting, the Redesign-only rows live only here, and
/// search finds the tab and each row.
@MainActor @Suite struct RedesignSettingsTabTests {
    private let previous = ThemeRuntime.input

    private func library() -> ThemeLibrary {
        let lib = ThemeLibrary(defaults: UserDefaults(suiteName: "cw.redesign-tab.tests.\(UUID().uuidString)")!, pinned: nil)
        lib.controlsAppearance = false
        return lib
    }

    @Test func masterSwitchAndThemePickerAgreeBothWays() {
        defer { ThemeRuntime.apply(previous) }
        let lib = library()
        lib.setTheme("ocean")
        let page = RedesignSettingsView(context: SettingsPagesFidelityTests.context(), library: lib)
        #expect(!page.master.isOn)
        #expect(page.gated.allSatisfy { $0.inertReason == RedesignSettingsView.offReason })
        // The theme picker turns Redesign on: the switch follows and the rows wake.
        lib.setTheme(ThemeDefinition.dither.id)
        #expect(page.master.isOn)
        #expect(page.gated.allSatisfy { $0.inertReason == nil })
        // The switch turns it off, and on again: the picker follows.
        page.master.onChange?(false)
        #expect(!lib.isRedesignOn && !page.master.isOn)
        lib.setTheme("ocean")
        page.master.onChange?(true)
        #expect(lib.isRedesignOn && lib.preference == ThemeDefinition.dither.id && page.master.isOn)
        // Off from the switch brings back the theme it replaced.
        page.master.onChange?(false)
        #expect(!lib.isRedesignOn && lib.preference == "ocean" && !page.master.isOn)
    }

    @Test func pickerDefaultsForAnUpgrade() {
        // A stored document from a build without the keys: stacked on, account card off.
        let old = ClientSettings(decoding: .object(["glassOpacity": .number(60)]))
        #expect(old.bool("redesignStackedPicker"))
        #expect(!old.bool("redesignPickerAccount"))
    }

    @Test func searchFindsTheTabAndEveryRow() {
        let ids = ["redesign", "redesign-picture", "background-dim", "accent-color", "ignore-reduce-transparency", "composer-collapse",
                   "redesign-stacked-picker", "redesign-picker-account"]
        #expect(SettingsSearch.search("redesign").first?.id == "redesign")
        for id in ids {
            let item = SettingsSearch.item(id)
            #expect(item?.to == .redesign, "\(id)")
            #expect(SettingsSearch.search(item?.title ?? id).contains { $0.id == id }, "\(id)")
            #expect(SettingsSearch.items.filter { $0.id == id }.count == 1, "\(id) once")
            #expect(DitherSettingsSection.home(of: .redesign, anchor: id) == .redesign)
        }
        let page = RedesignSettingsView(context: SettingsPagesFidelityTests.context(), library: library())
        for id in ids { #expect(page.anchor(id) != nil, "\(id) on the tab") }
    }

    @Test func movedRowsLeaveTheirOldPages() {
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let context = SettingsPagesFidelityTests.context()
        let titles = ["Redesign picture", "Background dim", "Accent color", "Ignore Reduce Transparency", "Collapse composer on scroll", "Redesign"]
        func rowTitles(_ view: NSView) -> [String] {
            ((view as? SettingsRowView).map { [$0.title] } ?? []) + view.subviews.flatMap(rowTitles)
        }
        for page in [AppearanceSettingsView(context: context), GeneralSettingsView(context: context), ExperimentalSettingsView(context: context)] as [SettingsPageBase] {
            page.frame = NSRect(x: 0, y: 0, width: 800, height: page.height(forWidth: 800))
            page.layoutSubtreeIfNeeded()
            let found = rowTitles(page)
            for t in titles { #expect(!found.contains(t), "\(t) on \(type(of: page))") }
        }
        #expect(DitherSettingsSection.redesign.slices.map(\.page) == [.redesign])
        #expect(DitherSettingsSection.groups.contains { $0.sections.contains(.redesign) })
    }
}
