import AppKit
import Testing
import DesignSystem
@testable import Features

/// Redesign's settings sections keep every setting: each search result lands in a section that shows it.
@MainActor
struct DitherSettingsLayoutTests {
    /// The section with real pages for `page` and empty stand-ins for the others.
    static func build(_ section: DitherSettingsSection, page: SettingsSection) -> DitherSettingsSectionView {
        let context = SettingsPagesFidelityTests.context()
        let pages: [NSView & SettingsGroupRow] = section.slices.map { slice in
            guard slice.page == page else { return SettingsStackView() }
            return slice.page == .storage ? StorageSettingsView(context: context) : GeneralSettingsView(context: context)
        }
        let v = DitherSettingsSectionView(section: section, pages: pages)
        v.frame = NSRect(x: 0, y: 0, width: 800, height: 4000)
        v.layoutSubtreeIfNeeded()
        return v
    }

    @Test func everySearchResultHasASection() {
        for item in SettingsSearch.items where item.to != .diagnostics && item.to != .licenses {
            #expect(DitherSettingsSection.home(of: item.to, anchor: item.anchor) != nil, "\(item.id)")
        }
    }

    @Test func generalAndStorageSettingsShowWhereSearchSendsThem() {
        let context = SettingsPagesFidelityTests.context()
        let full: [SettingsSection: SettingsStackView] = [.general: GeneralSettingsView(context: context), .storage: StorageSettingsView(context: context)]
        for item in SettingsSearch.items where item.to == .general || item.to == .storage {
            // Rows this client doesn't build (T3's CLI and telemetry rows) have no anchor anywhere.
            guard full[item.to]?.anchor(item.anchor) != nil else { continue }
            guard let home = DitherSettingsSection.home(of: item.to, anchor: item.anchor) else { Issue.record("\(item.id)"); continue }
            let view = Self.build(home, page: item.to)
            #expect(view.anchor(item.anchor, page: item.to) != nil, "\(item.id) in \(home)")
        }
    }

    @Test func slicesHideTheRestOfThePage() {
        let view = Self.build(.notifications, page: .general)
        let general = view.pages[0] as! GeneralSettingsView
        #expect(view.anchor("thread-notifications", page: .general) != nil)
        #expect(view.anchor("send-shortcut", page: .general) == nil)
        #expect(view.anchor("default-model", page: .general) == nil)
        let behavior = general.anchor("behavior") as! SettingsSectionView
        #expect(behavior.title == "Alerts")
        // Three rows and no scope picker: one short card.
        #expect(view.height(forWidth: 800) < 330)
    }

    @Test func deepLinksLandInTheirSection() {
        #expect(DitherSettingsSection.home(of: .providers) == .models)
        #expect(DitherSettingsSection.home(of: .projects) == .project)
        #expect(DitherSettingsSection.home(of: .scheduledTasks) == .scheduledTasks)
        #expect(DitherSettingsSection.home(of: .connections) == .machines)
        #expect(DitherSettingsSection.parent(of: .diagnostics) == .advanced)
    }
}
