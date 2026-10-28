import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

@MainActor
struct SettingsConcernTests {
    @Test func routesReachTheNewPagesAndRetainOldAliases() {
        for section in [SettingsSection.chat, .diffs, .threads, .browser, .devices, .worktrees, .access, .maintenance, .about] {
            #expect(SettingsSection.fromPath("/settings/" + section.rawValue) == section)
        }
        #expect(SettingsSection.fromPath("/settings/labs") == .beta)
        #expect(SettingsSection.fromPath("/settings/beta") == .beta)
        #expect(SettingsSection.fromPath("/settings/storage") == .maintenance)
        #expect(SettingsSection.fromPath("/settings/integrations") == .browser)
        #expect(SettingsSection.fromPath("/settings/open-source-licenses") == .licenses)
        #expect(SettingsSection.fromPath("/threads") == nil)
    }

    @Test func pageNamesAndOrderFollow3814WithExperimentalLast() {
        #expect(SettingsSection.navSections.map(\.label) == ["General", "Appearance", "Chat", "Diffs & pull requests", "Keybindings", "SnapShots", "Providers", "Threads", "Browser", "Devices", "Scheduled tasks", "Projects", "Source control", "Worktrees", "Environments", "Sharing & access", "Maintenance", "Labs", "About", "Archive", "Experimental"])
        #expect(SettingsSection.diagnostics.parent == .maintenance)
        #expect(SettingsSection.licenses.parent == .about)
    }

    @Test func movedRowsKeepTheirSearchAnchorsAndDestinations() {
        let context = SettingsPagesFidelityTests.context()
        let cases: [(SettingsSection, [String], [String])] = [
            (.general, ["thread-notifications", "project-grouping", "working-shelf", "quit-confirmation"], ["send-shortcut", "app-version"]),
            (.chat, ["composer-rich-text", "send-shortcut", "follow-up-behavior"], ["thread-notifications", "diff-layout"]),
            (.diffs, ["diff-layout", "diff-color-scheme", "proactive-panels", "pull-request-links-open-in-app"], ["browser-link-target"]),
            (.threads, ["default-model", "new-threads", "response-streaming", "text-generation-model"], ["compact-idle-threads", "worktree-submodules"]),
            (.providers, ["compact-idle-threads"], ["default-model"]),
            (.browser, ["browser-profiles", "browser-search-engine", "browser-recording-frame-rate"], ["pull-request-links-open-in-app", "device-hosts"]),
            (.devices, ["device-hosts"], ["browser-profiles"]),
            (.worktrees, ["worktree-submodules", "start-from-origin", "worktree-branch-naming", "storage-worktree-keep-when"], ["source-control-writing-style"]),
            (.maintenance, ["provider-update-checks", "background-activity", "diagnostics"], ["app-version"]),
            (.about, ["app-version", "privacy-policy", "open-source-licenses"], ["diagnostics"]),
        ]
        for (section, present, absent) in cases {
            let page = ConcernSettingsView(context: context, section: section)
            page.refresh()
            for id in present { #expect(page.anchor(id) != nil, "\(id) in \(section)") }
            for id in absent { #expect(page.anchor(id) == nil, "\(id) outside \(section)") }
        }
        for (id, section) in [("snooze-options", SettingsSection.threads), ("git-fetch-interval", .maintenance), ("network-access", .access), ("legacy-plan-mode", .beta)] {
            #expect(SettingsSearch.items.first { $0.id == id }?.to == section)
        }
    }

    @Test func labsKeepsBetaAboveLegacyFeatures() {
        let page = BetaSettingsView(context: SettingsPageContext())
        #expect(page.items.compactMap { ($0 as? SettingsSectionView)?.title } == ["Beta", "Legacy features"])
        #expect(page.anchor("boring-sidebar") != nil)
        #expect(page.anchor("legacy-plan-mode") != nil)
    }
}
